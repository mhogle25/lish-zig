# Error handling

lish splits failure by **intent**, the way Rust/Go/Zig do; there is no
`try`/`catch`.

- **Panics** are bugs and sandbox violations (every runtime-error category). They
  are **fatal and uncatchable from within a script**. Recovering from a panic is
  the *host's* job: the host catches the error at the Zig boundary. Scripts never
  catch panics.
- **Expected failure** is a **value** the script inspects with ordinary ops. No
  new control flow, nothing hidden.

There are two value shapes, split by whether the failure carries a reason.

## Optional: a value, or `$none`

For *mere absence*: a lookup miss, `first` of an empty list. Because `$none` is the
only falsy value, Optionals compose with existing ops for free:

```
or (kvget :config "port") 8080      ## default on absence
if (kvget :config "verbose") ...    ## branch on presence
assert (kvget :config "name")       ## value-or-panic ("expect")
```

### `given`: the Optional binding-if

```
given NAME SOURCE OK-BODY [ELSE-BODY]
```

Evaluate `SOURCE`; if it is non-`$none`, bind it to `NAME` and run `OK-BODY`;
otherwise run `ELSE-BODY` (or yield `$none` when omitted). It is `let`+`if` fused:
the ok-body sees the binding, the else-body does not, and the binding does not leak
past the form.

```
given port (kvget :config "port")
   (concat "listening on " (string :port))
   "no port configured"
```

## Result: `[tag payload]`, for failure with a reason

A Result is a 2-element list whose first slot is the tag (`ok` or `err`) and whose
second slot is the payload:

```
ok 5            ## => ["ok" 5]
err "boom"      ## => ["err" "boom"]
```

Tags are bare-term strings, so they match unquoted in `match`/`is`. The payload of
an `err` is just a message or value; there are no in-script error categories
(categories live host-side, for `RuntimeErr` inspection and message quality).

### Reading a Result

The tag and payload are the existing list ops `first` and `last`; there are no
special accessors:

```
first (ok 5)    ## => "ok"   (the tag)
last (ok 5)     ## => 5       (the payload)
```

Dispatch on the tag with `match`, binding the payload inline where an arm reuses it:

```
match (first :r)
   ok  (let v (last :r) (use :v))
   err (let e (last :r) (recover :e))
```

### The Result vocabulary (stdlib macros)

| Macro | Meaning |
|---|---|
| `ok V` | construct a success Result wrapping `V` |
| `err M` | construct a failure Result wrapping message `M` |
| `pass R` | the payload if `R` is `ok`, else `$none` (Result -> Optional) |
| `fail R` | the payload if `R` is `err`, else `$none` (Result -> Optional) |
| `unwrap R` | the payload if `R` is `ok`, else `panic` with the err payload |

`pass`/`fail` project a Result down to an Optional, so a Result flows straight into
the Optional tools above:

```
or (pass :r) "default"                 ## ok payload, or a default
given v (pass :r) (use :v) (recover)   ## bind the ok payload, else recover
```

Nested `given`s over `pass`-projected sources chain and short-circuit to `$none` on
the first failure.
