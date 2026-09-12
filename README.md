# Recall

Recall is searchable command **and output** history for Nushell. It records each
interactive command together with its working directory, timestamp, and final
structured Nushell value in a local SQLite database.

```nu
recall find "failed"
recall output 42 | where status == "failed"
recall insert 42
```

Recall is written entirely in Nushell. There is no compiled plugin or external
SQLite dependency.

## Requirements

- Nushell 0.113 or newer
- A Nushell build with SQLite support (included in standard builds)

Recall is developed and tested against Nushell 0.113.1.

## Install

Clone Recall into Nushell's scripts directory:

```nu
let scripts = ($nu.default-config-dir | path join "scripts")
mkdir $scripts
git clone https://github.com/noahfraiture/recall ($scripts | path join "recall")
```

Add these lines to `config.nu`:

```nu
use recall/recall.nu *
recall init
```

Open the configuration with `config nu`, add the lines, and restart Nushell.
`recall init` is intentionally quiet and safe to run whenever a shell starts.

If you keep the repository elsewhere, use its absolute path instead:

```nu
use /absolute/path/to/recall/recall.nu *
recall init
```

## Use

### Browse and search

```nu
recall                     # Latest 25 commands
recall --limit 100
recall find cargo          # Search commands and complete saved outputs
recall find "connection refused" --limit 10
recall show 42             # Metadata for one entry
```

`recall find` is case-insensitive and searches both the original command text
and the complete NUON-serialized output, not just the short preview displayed
in the result table.

### Reuse commands

```nu
recall command 42          # Return the command as a string
recall insert 42           # Put it into the command-line buffer for editing
recall insert 42 --accept  # Put it into the buffer and run it immediately
recall pick                # Fuzzy-pick an entry and put its command in the prompt
```

The fuzzy picker can instead return metadata or the saved output:

```nu
recall pick --show
recall pick --output
```

### Reuse outputs

Recall restores standard Nushell types, so an old output can become the input
to a new pipeline:

```nu
recall output 42
recall output 42 | where size > 10mb
recall output 42 --raw     # Return its serialized NUON representation
```

Dates, durations, filesizes, binaries, records, lists, and tables round-trip
through NUON. Values that Nushell can only serialize as text, such as some
closures or custom values from another plugin, are restored as their textual
representation.

### Import existing command history

Recall records new commands after installation. To make it useful as a regular
history browser immediately, import recent entries from Nushell's existing
history:

```nu
recall import                 # Last 1,000 native history entries
recall import --limit 10_000
```

Imports are idempotent for a given native history index and command. Imported
entries have commands but no saved outputs.

### Pause recording

```nu
recall pause
recall resume
```

Pause applies to the current shell session. Recall also respects Nushell's
`history.ignore_space_prefixed` setting: when enabled, a command beginning with
a space or tab is not recorded.

## Keyboard shortcut

This optional binding opens the fuzzy picker with `Alt+R`:

```nu
$env.config.keybindings ++= [{
    name: recall_picker
    modifier: alt
    keycode: char_r
    mode: [emacs vi_normal vi_insert]
    event: {
        send: executehostcommand
        cmd: "recall pick"
    }
}]
```

Place it in `config.nu` after `recall init`.

## Configuration

On first initialization Recall creates:

- Configuration: `$nu.default-config-dir/recall.toml`
- Database: `$nu.data-dir/recall/history.sqlite3`

The initial TOML configuration is:

```toml
[storage]
max_size = "1 GiB"
auto_prune = false
```

`max_size` is the maximum combined size of retained NUON output payloads. It
accepts Nushell filesize strings such as `500 MiB`, `2 GiB`, or `10 GB`.

When `auto_prune` is `true`, Recall clears the oldest output payloads after a
capture once the limit is exceeded. It retains their command, timestamp,
working directory, output preview, and `pruned` status, so Recall remains useful
as ordinary command history. With the default `false`, Recall only reports that
the limit has been exceeded.

Configuration is read on every capture, so changes take effect without
restarting the shell.

```nu
recall config               # Effective values and config path
recall config path
recall status               # Storage usage and runtime state
recall prune --dry-run
recall prune                # Enforce max_size now
recall vacuum               # Return freed SQLite pages to the filesystem
```

Pruning reduces Recall's logical captured size immediately. SQLite normally
reuses the freed pages; run `recall vacuum` if the physical file also needs to
shrink.

Recall stores command text and outputs unencrypted. On Unix systems it sets the
configuration and database files to mode `0600` and its data directory to
`0700`. Anyone who can read the database can read its history; use
`recall pause` or a space-prefixed command around sensitive work.

## What gets captured

Recall creates one entry for each submitted interactive REPL command and saves
the final value that reaches Nushell's display hook. For example, this stores
the final filtered table:

```nu
ls | where size > 10kb
```

There are several boundaries imposed by Nushell's hook model:

- Hooks run in interactive shells, not `nu script.nu` or `nu -c ...`.
- Intermediate pipeline values are not recorded.
- Output written directly to the terminal by an external command bypasses the
  display hook.
- Direct `print`, stderr, parser diagnostics, and full-screen TUI output are not
  captured as output values.

External output is captured when it becomes part of a Nushell pipeline and the
pipeline produces a final value, for example:

```nu
git status | lines
```

Recall's hooks preserve the existing output renderer. Capture errors are
isolated so a database or serialization problem cannot prevent a command's
normal output from being displayed.

## Test

Run the automated suite from the repository root:

```nu
nu --no-config-file --no-history tests/test_recall.nu
```

The tests use temporary configuration and database paths and do not touch your
normal Recall or Nushell history.

## License

MIT
