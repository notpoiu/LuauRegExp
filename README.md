# LuauRegExp

A full-featured regular expression engine written in pure Luau. Supports Perl/PCRE2 syntax including lookaround, atomic groups, backreferences, named captures, and Unicode. Ships with a grep module for searching text and codebases.

Works in **Roblox**, **Lune**, and any Luau runtime.

## Installation

### Bundled (Roblox / single file)

Build the bundle:

```sh
lune run build.luau
```

This produces `dist/RegExp.luau` and `dist/RegExp.readable.luau`. Copy either into your project.

```lua
local RegExp = require(path.to.RegExp)
local Regexp = RegExp.Regexp
local Grep = RegExp.Grep
```

### Source (Lune)

Use the modules directly from `src/`:

```lua
local Regexp = require("./src/Regexp")
local Grep = require("./src/Grep")
```

## Quick Start

```lua
local Regexp = require(...) -- however you load it

-- Simple match
local match = Regexp.Search("\\bfunction\\b", "local function foo()", Regexp.LikePerl)
print(match.text) --> "function"

-- Find all matches
local matches = Regexp.FindAll("\\d+", "port 8080 and 443", Regexp.LikePerl)
for _, m in matches do
    print(m.text) --> "8080", "443"
end

-- Check if a pattern matches
local ok = Regexp.IsMatch("[a-z]+@[a-z]+", "user@host", Regexp.LikePerl)

-- Full match (entire string must match)
local ok = Regexp.FullMatch("^\\d{3}-\\d{4}$", "555-1234", Regexp.LikePerl)

-- Compile once, use many times
local re = Regexp.Parse("(?P<key>\\w+)=(?P<val>\\w+)", Regexp.LikePCRE2)
local m = re:Search("color=red")
print(m.named.key.text) --> "color"
print(m.named.val.text) --> "red"
```

## API Reference

### Flags

Flags control parsing behavior. Combine with `bit32.bor()`.

| Flag | Description |
|---|---|
| `Regexp.NoParseFlags` | No flags (default) |
| `Regexp.FoldCase` | Case-insensitive matching |
| `Regexp.Literal` | Treat pattern as a literal string |
| `Regexp.MatchNL` | `.` matches `\n` |
| `Regexp.PerlX` | Perl extensions (`\b`, `\Q...\E`, etc.) |
| `Regexp.PerlClasses` | `\d`, `\s`, `\w` and their negations |
| `Regexp.UnicodeGroups` | `\p{...}` Unicode classes |
| `Regexp.NeverNL` | `.` never matches `\n` (overrides MatchNL) |
| `Regexp.Latin1` | Latin-1 mode (single-byte) |
| `Regexp.OneLine` | `^`/`$` match start/end of text only (not lines) |
| `Regexp.NonGreedy` | Quantifiers are non-greedy by default |
| `Regexp.PCRE2` | PCRE2 extensions (lookaround, atomic groups, backrefs) |
| **`Regexp.LikePerl`** | `PerlX + PerlClasses + UnicodeGroups + OneLine` |
| **`Regexp.LikePCRE2`** | `LikePerl + PCRE2` |

For most use cases, use `Regexp.LikePerl` or `Regexp.LikePCRE2`.

### Regexp (static methods)

#### `Regexp.Parse(pattern, flags, status?) -> re`

Compile a pattern into a reusable regex object. Returns `nil` on parse error (check `status:Text()` for the message).

```lua
local status = Regexp.newStatus()
local re = Regexp.Parse("\\d+", Regexp.LikePerl, status)
if re == nil then
    print("Error:", status:Text())
end
```

#### `Regexp.Search(pattern, text, flags?, status?, startByte?) -> match?, err?`

One-shot search. Compiles the pattern and finds the first match.

#### `Regexp.FindAll(pattern, text, flags?, status?, maxMatches?, startByte?) -> matches?, err?`

One-shot find all. Returns an array of match objects.

#### `Regexp.IsMatch(pattern, text, flags?, status?, startByte?) -> boolean, err?`

Returns `true` if the pattern matches anywhere in the text.

#### `Regexp.FullMatch(pattern, text, flags?, status?) -> boolean, err?`

Returns `true` only if the pattern matches the **entire** text.

#### `Regexp.newStatus() -> status`

Create a status object for capturing parse errors.

### Regex Object (compiled pattern)

Returned by `Regexp.Parse()`.

#### `re:Search(text, startByte?) -> match?, err?`

Find the first match in `text`.

#### `re:FindAll(text, maxMatches?, startByte?) -> matches?, err?`

Find all matches (up to `maxMatches`).

#### `re:IsMatch(text, startByte?) -> boolean, err?`

Check if the pattern matches anywhere.

#### `re:FullMatch(text) -> boolean, err?`

Check if the pattern matches the entire text.

#### `re:ToString() -> string`

Return the pattern string.

#### `re:Dump() -> string`

Return a debug representation of the parsed AST.

#### `re:NumCaptures() -> number`

Return the number of capture groups.

#### `re:Simplify() -> re`

Return a simplified/optimized version of the regex.

### Match Object

Returned by `Search` and `FindAll`.

```lua
{
    start: number,      -- start byte position (1-indexed, inclusive)
    finish: number,     -- end byte position (1-indexed, exclusive)
    text: string,       -- matched text
    captures: {         -- array of capture groups (by index)
        [1] = {
            index: number,
            start: number,
            finish: number,
            text: string,
            name: string?,  -- if named capture
        },
        ...
    },
    named: {            -- named captures (by name), nil if none
        [name] = capture,
        ...
    }?,
}
```

### Grep Module

#### `Grep.searchText(patternOrRegexp, text, options?) -> matches?, err?`

Search a single string. Returns an array of match objects enriched with line information.

**Options:**
| Field | Type | Default | Description |
|---|---|---|---|
| `flags` | `number` | `0` | Parse flags (ignored if passing a compiled regex) |
| `lineMode` | `boolean` | `true` | Match per-line (`true`) or whole text (`false`) |
| `maxMatches` | `number` | `inf` | Max matches to return |
| `startByte` | `number?` | `nil` | Byte offset to start searching |
| `path` | `string?` | `nil` | Attach a path identifier to matches |

**Line-mode match fields** (in addition to standard match fields):
| Field | Description |
|---|---|
| `line` | Line number (1-indexed) |
| `column` | Column number (1-indexed) |
| `lineText` | Full text of the matching line |
| `path` | Path identifier (if provided) |

#### `Grep.searchFiles(files, patternOrRegexp, options?) -> result?, err?`

Search an array of in-memory files. Each file entry should have `name` (string) and `source` (string). Works in Roblox.

```lua
local files = {
    { name = "main.lua", source = 'print("hello")' },
    { name = "util.lua", source = "local function helper() end" },
}

local result = Grep.searchFiles(files, "\\bfunction\\b", {
    flags = Regexp.LikePerl,
})

print(result.totalMatches)  --> 1
for _, file in result.results do
    print(file.path, file.matchCount)
    for _, match in file.matches do
        print("  ", match.line, match.text)
    end
end
```

**Options:** same as `searchText`, plus:
| Field | Type | Default | Description |
|---|---|---|---|
| `maxMatchesPerFile` | `number` | `inf` | Max matches per file |

**Result:**
```lua
{
    pattern: string,
    totalMatches: number,
    fileCount: number,        -- files with at least one match
    searchedFiles: number,
    results: {
        {
            path: string,
            matchCount: number,
            matches: { match, ... },
        },
        ...
    },
}
```

#### `Grep.searchPath(rootPath, patternOrRegexp, options?) -> result?, err?`

Recursively search a directory. **Lune only** (requires `@lune/fs`).

**Additional options:**
| Field | Type | Default | Description |
|---|---|---|---|
| `extensions` | `table?` | code files | File extension filter |
| `includeHidden` | `boolean` | `true` | Include dotfiles/dotdirs |

### Roblox Example

Search all scripts in a game for a pattern:

```lua
local RegExp = require(path.to.RegExp)
local Regexp = RegExp.Regexp
local Grep = RegExp.Grep

-- Collect scripts
local scripts = {}
for _, desc in game:GetDescendants() do
    if desc:IsA("LuaSourceContainer") then
        table.insert(scripts, {
            name = desc:GetFullName(),
            source = desc.Source,
        })
    end
end

-- Search
local result = Grep.searchFiles(scripts, "\\bRemoteEvent\\b", {
    flags = Regexp.LikePerl,
    maxMatchesPerFile = 10,
})

for _, file in result.results do
    print(file.path .. ": " .. file.matchCount .. " matches")
    for _, match in file.matches do
        print(string.format("  L%d: %s", match.line, match.lineText))
    end
end
```

## Supported Syntax

### Basics
| Syntax | Description |
|---|---|
| `.` | Any character (except `\n` by default) |
| `\d`, `\D` | Digit / non-digit |
| `\s`, `\S` | Whitespace / non-whitespace |
| `\w`, `\W` | Word character / non-word |
| `\b`, `\B` | Word boundary / non-boundary |
| `[abc]`, `[a-z]`, `[^abc]` | Character classes |
| `[:alpha:]` | POSIX classes (inside `[...]`) |
| `\A`, `\z` | Start / end of text |
| `^`, `$` | Start / end of line (or text with `OneLine`) |

### Quantifiers
| Syntax | Description |
|---|---|
| `*`, `+`, `?` | 0+, 1+, 0 or 1 (greedy) |
| `*?`, `+?`, `??` | Non-greedy variants |
| `*+`, `++`, `?+` | Possessive variants (PCRE2) |
| `{n}`, `{n,}`, `{n,m}` | Counted repetition |

### Groups & Captures
| Syntax | Description |
|---|---|
| `(...)` | Capturing group |
| `(?:...)` | Non-capturing group |
| `(?P<name>...)` | Named capture (Python style) |
| `(?<name>...)` | Named capture (PCRE style) |
| `(?i)`, `(?m)` | Inline flags |
| `(?i:...)` | Scoped flags |

### PCRE2 Extensions
Requires `Regexp.LikePCRE2` or `Regexp.PCRE2` flag.

| Syntax | Description |
|---|---|
| `(?=...)` | Positive lookahead |
| `(?!...)` | Negative lookahead |
| `(?<=...)` | Positive lookbehind |
| `(?<!...)` | Negative lookbehind |
| `(?>...)` | Atomic group |
| `\1`, `\2` | Backreference (by number) |
| `\k<name>` | Backreference (by name) |
| `(?P=name)` | Backreference (Python style) |

## Building

Requires [Rokit](https://github.com/rojo-rbx/rokit) for tool management.

```sh
# Install tools
rokit install

# Run tests
lune run tests/run.luau

# Run benchmarks
lune run benchmarks/run.luau

# Build bundled output
lune run build.luau
```

## License

MIT
