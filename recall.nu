# Recall: searchable command and output history for Nushell.

const RECALL_SCHEMA_VERSION = "1"

def recall-default-config [] {
    {
        storage: {
            max_size: "1 GiB"
            auto_prune: false
        }
    }
}

def recall-config-path [] {
    $env.RECALL_CONFIG_PATH?
    | default ($nu.default-config-dir | path join "recall.toml")
    | path expand
}

def recall-db-path [] {
    $env.RECALL_DB_PATH?
    | default ($nu.data-dir | path join "recall" "history.sqlite3")
    | path expand
}

def recall-load-config [] {
    let defaults = (recall-default-config)
    let path = (recall-config-path)
    let configured = if ($path | path exists) {
        open $path
    } else {
        {}
    }
    let config = ($defaults | merge deep $configured)

    let max_size_bytes = try {
        $config.storage.max_size | into filesize | into int
    } catch {|error|
        error make {
            msg: $"Invalid Recall storage.max_size in ($path)"
            help: "Use a Nushell filesize string such as '500 MiB' or '1 GiB'."
            inner: $error
        }
    }

    if (($config.storage.auto_prune | describe) != "bool") {
        error make {
            msg: $"Invalid Recall storage.auto_prune in ($path)"
            help: "Set storage.auto_prune to true or false."
        }
    }

    $config | upsert storage.max_size_bytes $max_size_bytes
}

def recall-restrict-file [path: path] {
    if $nu.os-info.family == "unix" {
        try { ^chmod 600 $path e>| ignore } catch { null }
    }
}

def recall-ensure-config [] {
    let path = (recall-config-path)
    if not ($path | path exists) {
        mkdir ($path | path dirname)
        recall-default-config | to toml | save $path
    }
    recall-restrict-file $path
}

def recall-ensure-db [] {
    let path = (recall-db-path)

    if not ($path | path exists) {
        let directory = ($path | path dirname)
        mkdir $directory
        if $nu.os-info.family == "unix" {
            try { ^chmod 700 $directory } catch { null }
        }
        {key: "schema_version", value: $RECALL_SCHEMA_VERSION}
        | into sqlite $path --table-name recall_meta
    }
    recall-restrict-file $path

    let db = (open $path)
    $db | query db "PRAGMA journal_mode = WAL" | ignore
    $db | query db "PRAGMA busy_timeout = 5000" | ignore
    $db | query db "
        CREATE TABLE IF NOT EXISTS entries (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id        TEXT NOT NULL,
            source            TEXT NOT NULL DEFAULT 'recall',
            source_id         TEXT,
            command           TEXT NOT NULL,
            cwd               TEXT NOT NULL,
            started_at_ns     INTEGER NOT NULL,
            finished_at_ns    INTEGER,
            duration_ns       INTEGER,
            status            TEXT NOT NULL DEFAULT 'running',
            output_type       TEXT,
            output_nuon       TEXT,
            output_preview    TEXT,
            output_bytes      INTEGER NOT NULL DEFAULT 0,
            nu_version        TEXT NOT NULL
        )
    " | ignore
    $db | query db "
        CREATE INDEX IF NOT EXISTS entries_started_at_idx
        ON entries(started_at_ns DESC, id DESC)
    " | ignore
    $db | query db "
        CREATE UNIQUE INDEX IF NOT EXISTS entries_source_idx
        ON entries(source, source_id)
        WHERE source_id IS NOT NULL
    " | ignore
    $db | query db "
        INSERT OR REPLACE INTO recall_meta(key, value)
        VALUES ('schema_version', ?)
    " --params [$RECALL_SCHEMA_VERSION] | ignore
}

def recall-query [sql: string, params: any = []] {
    let path = (recall-db-path)
    if not ($path | path exists) {
        recall-ensure-db
    }
    let db = (open $path)
    $db | query db "PRAGMA busy_timeout = 5000" | ignore
    $db | query db $sql --params $params
}

def recall-entry [id: int] {
    let rows = (recall-query "
        SELECT id, session_id, source, source_id, command, cwd,
               started_at_ns, finished_at_ns, duration_ns, status,
               output_type, output_nuon, output_preview, output_bytes,
               nu_version
        FROM entries
        WHERE id = ?
    " [$id])

    if ($rows | is-empty) {
        error make {msg: $"Recall entry ($id) does not exist."}
    }

    $rows | first
}

def recall-present-entry [row: record] {
    {
        id: $row.id
        when: ($row.started_at_ns | into datetime)
        command: $row.command
        output: ($row.output_preview | default "")
        type: ($row.output_type | default "")
        size: ($row.output_bytes | into filesize)
        status: $row.status
        cwd: $row.cwd
    }
}

def recall-list-rows [limit: int] {
    recall-query "
        SELECT id, command, cwd, started_at_ns, duration_ns, status,
               output_type, output_preview, output_bytes
        FROM entries
        ORDER BY started_at_ns DESC, id DESC
        LIMIT ?
    " [$limit]
}

def recall-prune-internal [dry_run: bool] {
    let config = (recall-load-config)
    let max_bytes = $config.storage.max_size_bytes
    let before = (
        recall-query "SELECT COALESCE(SUM(output_bytes), 0) AS bytes FROM entries"
        | first
        | get bytes
    )
    let candidates = (
        recall-query "
            SELECT COUNT(*) AS count
            FROM (
                SELECT id,
                       SUM(output_bytes) OVER (
                           ORDER BY started_at_ns DESC, id DESC
                       ) AS retained_bytes
                FROM entries
                WHERE output_bytes > 0
            )
            WHERE retained_bytes > ?
        " [$max_bytes]
        | first
        | get count
    )

    if not $dry_run and $candidates > 0 {
        recall-query "
            WITH ranked AS (
                SELECT id,
                       SUM(output_bytes) OVER (
                           ORDER BY started_at_ns DESC, id DESC
                       ) AS retained_bytes
                FROM entries
                WHERE output_bytes > 0
            )
            UPDATE entries
            SET output_nuon = NULL,
                output_bytes = 0,
                status = 'pruned'
            WHERE id IN (
                SELECT id FROM ranked WHERE retained_bytes > ?
            )
        " [$max_bytes] | ignore
    }

    let after = if $dry_run {
        $before
    } else {
        recall-query "SELECT COALESCE(SUM(output_bytes), 0) AS bytes FROM entries"
        | first
        | get bytes
    }

    {
        dry_run: $dry_run
        outputs_pruned: $candidates
        before: ($before | into filesize)
        after: ($after | into filesize)
        max_size: ($max_bytes | into filesize)
    }
}

# List recently recorded commands and their output previews.
export def main [
    --limit (-l): int = 25
] {
    recall-list-rows $limit | each {|row| recall-present-entry $row}
}

# Search both command text and complete serialized output.
export def "recall find" [
    query: string
    --limit (-l): int = 50
] {
    recall-query "
        SELECT id, command, cwd, started_at_ns, duration_ns, status,
               output_type, output_preview, output_bytes
        FROM entries
        WHERE instr(lower(command), lower(?)) > 0
           OR instr(lower(COALESCE(output_nuon, output_preview, '')), lower(?)) > 0
        ORDER BY started_at_ns DESC, id DESC
        LIMIT ?
    " [$query $query $limit]
    | each {|row| recall-present-entry $row}
}

# Return all metadata for one history entry, excluding its full output payload.
export def "recall show" [id: int] {
    recall-entry $id | reject output_nuon
}

# Restore a saved output as a Nushell value.
export def "recall output" [
    id: int
    --raw
] {
    let entry = (recall-entry $id)
    if ($entry.output_nuon | is-empty) {
        error make {
            msg: $"Recall entry ($id) has no stored output."
            help: $"Its current status is '($entry.status)'."
        }
    }

    if $raw {
        $entry.output_nuon
    } else {
        $entry.output_nuon | from nuon
    }
}

# Return only the original command text for an entry.
export def "recall command" [id: int] {
    recall-entry $id | get command
}

# Put an earlier command back into the interactive command-line buffer.
export def --env "recall insert" [
    id: int
    --accept (-a)
] {
    let command = (recall-entry $id | get command)
    if $accept {
        commandline edit --replace --accept $command
    } else {
        commandline edit --replace $command
    }
}

# Fuzzy-pick history. By default the chosen command is placed in the prompt.
export def --env "recall pick" [
    --limit (-l): int = 200
    --output (-o)
    --show (-s)
] {
    let selected = (
        recall-list-rows $limit
        | input list --fuzzy --no-footer --display {|row|
            let preview = ($row.output_preview | default "")
            $"#($row.id)  ($row.command)  ($preview)"
        } "Recall"
    )

    if ($selected | is-empty) {
        return
    }

    if $output {
        recall output $selected.id
    } else if $show {
        recall show $selected.id
    } else {
        commandline edit --replace $selected.command
    }
}

# Import existing Nushell command history as command-only Recall entries.
export def "recall import" [
    --limit (-l): int = 1000
] {
    let rows = (history | last $limit)
    let total = ($rows | length)
    let base = (date now | into int) - ($total * 1_000_000)
    mut imported = 0

    for row in ($rows | enumerate) {
        let command = ($row.item | get command)
        let native_index = ($row.item | get -o index | default $row.index | into string)
        let source_id = $"($native_index):($command | hash sha256)"
        let result = (recall-query "
            INSERT OR IGNORE INTO entries (
                session_id, source, source_id, command, cwd,
                started_at_ns, finished_at_ns, duration_ns, status,
                output_bytes, nu_version
            ) VALUES (?, 'nushell', ?, ?, ?, ?, ?, 0, 'imported', 0, ?)
            RETURNING id
        " [
            ($env.RECALL_SESSION_ID? | default "import")
            $source_id
            $command
            (pwd | into string)
            ($base + ($row.index * 1_000_000))
            ($base + ($row.index * 1_000_000))
            (version | get version)
        ])
        if not ($result | is-empty) {
            $imported += 1
        }
    }

    {imported: $imported, skipped: ($total - $imported), considered: $total}
}

# Show Recall configuration, storage usage, and runtime state.
export def "recall status" [] {
    recall-ensure-config
    recall-ensure-db
    let config = (recall-load-config)
    let totals = (
        recall-query "
            SELECT COUNT(*) AS entries,
                   COALESCE(SUM(CASE WHEN output_nuon IS NOT NULL THEN 1 ELSE 0 END), 0) AS outputs,
                   COALESCE(SUM(output_bytes), 0) AS output_bytes
            FROM entries
        "
        | first
    )
    let physical = (ls (recall-db-path) | first | get size)

    {
        entries: $totals.entries
        outputs: $totals.outputs
        captured_size: ($totals.output_bytes | into filesize)
        database_size: $physical
        max_size: ($config.storage.max_size_bytes | into filesize)
        over_limit: ($totals.output_bytes > $config.storage.max_size_bytes)
        auto_prune: $config.storage.auto_prune
        paused: ($env.RECALL_PAUSED? | default false)
        hooks_installed: ($env.RECALL_HOOKS_INSTALLED? | default false)
        database: (recall-db-path)
        config: (recall-config-path)
    }
}

# Show the effective TOML configuration and its location.
export def "recall config" [] {
    recall-ensure-config
    {
        path: (recall-config-path)
        values: (recall-load-config | reject storage.max_size_bytes)
    }
}

# Return the path to Recall's TOML configuration file.
export def "recall config path" [] {
    recall-ensure-config
    recall-config-path
}

# Prune oldest saved outputs until captured data fits storage.max_size.
export def "recall prune" [
    --dry-run (-n)
] {
    recall-prune-internal $dry_run
}

# Reclaim unused SQLite pages after pruning.
export def "recall vacuum" [] {
    recall-ensure-db
    let db = (open (recall-db-path))
    $db | query db "PRAGMA wal_checkpoint(TRUNCATE)" | ignore
    $db | query db "VACUUM" | ignore
}

# Stop recording in the current Nushell session.
export def --env "recall pause" [] {
    $env.RECALL_PAUSED = true
}

# Resume recording in the current Nushell session.
export def --env "recall resume" [] {
    $env.RECALL_PAUSED = false
}

# Internal hook: start a command history entry.
export def --env "recall __begin" [command?: string] {
    if ($env.RECALL_PAUSED? | default false) {
        return
    }

    let line = if $command == null { commandline } else { $command }
    if ($line | str trim | is-empty) {
        return
    }
    if (($line | str trim) =~ '^exit(?:\s|$)') {
        return
    }

    let ignores_prefixed = ($env.config.history.ignore_space_prefixed? | default true)
    if $ignores_prefixed and (
        ($line | str starts-with " ") or ($line | str starts-with (char tab))
    ) {
        return
    }

    let now = (date now | into int)
    let session = ($env.RECALL_SESSION_ID? | default (random uuid))
    $env.RECALL_SESSION_ID = $session
    let inserted = (recall-query "
        INSERT INTO entries (
            session_id, source, command, cwd, started_at_ns,
            status, output_bytes, nu_version
        ) VALUES (?, 'recall', ?, ?, ?, 'running', 0, ?)
        RETURNING id
    " [$session $line (pwd | into string) $now (version | get version)])

    $env.RECALL_ACTIVE_ID = ($inserted | first | get id)
    $env.RECALL_ACTIVE_STARTED_AT_NS = $now
}

# Internal hook: attach the final displayed Nushell value to a command.
export def "recall __capture" [entry_id?: int]: any -> nothing {
    let value = ($in | collect)
    let id = ($entry_id | default ($env.RECALL_ACTIVE_ID? | default (-1)))
    if $id < 0 {
        return
    }

    try {
        let nuon = ($value | to nuon --serialize)
        let preview = (
            $nuon
            | str replace --all (char nl) " "
            | str replace --all (char tab) " "
            | str substring 0..<240
        )
        let bytes = ($nuon | encode utf-8 | bytes length)
        let now = (date now | into int)
        recall-query "
            UPDATE entries
            SET finished_at_ns = ?,
                duration_ns = ? - started_at_ns,
                status = 'complete',
                output_type = ?,
                output_nuon = ?,
                output_preview = ?,
                output_bytes = ?
            WHERE id = ?
        " [$now $now ($value | describe) $nuon $preview $bytes $id] | ignore

        let config = (recall-load-config)
        if $config.storage.auto_prune {
            recall-prune-internal false | ignore
        }
    } catch {
        try {
            recall-query "
                UPDATE entries
                SET status = 'capture_error'
                WHERE id = ? AND status = 'running'
            " [$id] | ignore
        } catch { null }
        # Output history must never make a user's command fail to display.
        null
    }
}

# Internal hook: finalize an entry when no display value was captured.
export def --env "recall __finish" [] {
    let id = ($env.RECALL_ACTIVE_ID? | default (-1))
    if $id >= 0 {
        let now = (date now | into int)
        try {
            recall-query "
                UPDATE entries
                SET finished_at_ns = COALESCE(finished_at_ns, ?),
                    duration_ns = COALESCE(duration_ns, ? - started_at_ns),
                    status = CASE WHEN status = 'running' THEN 'no_output' ELSE status END
                WHERE id = ?
            " [$now $now $id] | ignore
        } catch {
            null
        }
    }

    if ($env.RECALL_ACTIVE_ID? | is-not-empty) {
        hide-env RECALL_ACTIVE_ID
    }
    if ($env.RECALL_ACTIVE_STARTED_AT_NS? | is-not-empty) {
        hide-env RECALL_ACTIVE_STARTED_AT_NS
    }
}

# Initialize storage and install Recall's interactive hooks for this session.
export def --env "recall init" [
    --no-hooks
] {
    recall-ensure-config
    recall-ensure-db

    if ($env.RECALL_SESSION_ID? | is-empty) {
        $env.RECALL_SESSION_ID = (random uuid)
    }
    if ($env.RECALL_PAUSED? | is-empty) {
        $env.RECALL_PAUSED = false
    }

    if $no_hooks or ($env.RECALL_HOOKS_INSTALLED? | default false) {
        return
    }

    $env.RECALL_ORIGINAL_PRE_EXECUTION = $env.config.hooks.pre_execution
    $env.RECALL_ORIGINAL_PRE_PROMPT = $env.config.hooks.pre_prompt
    $env.RECALL_ORIGINAL_DISPLAY_OUTPUT = $env.config.hooks.display_output

    $env.config.hooks.pre_execution = (
        $env.config.hooks.pre_execution
        | append { try { recall __begin } catch { null } }
    )
    $env.config.hooks.pre_prompt = (
        $env.config.hooks.pre_prompt
        | append { try { recall __finish } catch { null } }
    )

    let previous = $env.config.hooks.display_output
    let previous_type = ($previous | describe)
    if $previous_type == "string" {
        let renderer = if ($previous | str trim | is-empty) { "table" } else { $previous }
        $env.config.hooks.display_output = $"tee { recall __capture } | ($renderer)"
    } else if ($previous_type | str starts-with "closure") {
        let renderer = $previous
        $env.config.hooks.display_output = {|value|
            $value | tee { recall __capture } | do $renderer
        }
    } else {
        $env.config.hooks.display_output = {|value|
            $value | tee { recall __capture } | table
        }
    }

    $env.RECALL_HOOKS_INSTALLED = true
}
