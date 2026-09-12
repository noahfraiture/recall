use std/assert

def main [] {
    let test_root = (mktemp -d --tmpdir "recall-tests.XXXXXXXX")
    let config_path = ($test_root | path join "recall.toml")
    let db_path = ($test_root | path join "recall.sqlite3")

    with-env {
        RECALL_CONFIG_PATH: $config_path
        RECALL_DB_PATH: $db_path
    } {
        use ../recall.nu *

        recall init --no-hooks
        assert ($config_path | path exists) "recall init creates a TOML config"
        assert ($db_path | path exists) "recall init creates a SQLite database"
        assert equal ((recall config).values.storage.max_size) "1 GiB"
        assert equal ((recall config).values.storage.auto_prune) false
        if $nu.os-info.family == "unix" {
            let modes = (ls -l $config_path $db_path | get mode)
            assert ($modes | all {|mode| $mode == "rw-------"}) "history files are private"
        }

        recall __begin "[1 2 3] | math sum"
        6 | recall __capture
        recall __finish

        let entries = (recall)
        assert equal ($entries | length) 1
        assert equal ($entries.0.command) "[1 2 3] | math sum"
        assert equal ($entries.0.status) "complete"
        assert equal (recall output $entries.0.id) 6
        assert equal (recall command $entries.0.id) "[1 2 3] | math sum"

        let command_match = (recall find "math sum")
        assert equal ($command_match | length) 1

        recall __begin "produce a needle"
        {message: "output-only-needle", values: [1 2 3]} | recall __capture
        recall __finish
        let output_match = (recall find "output-only-needle")
        assert equal ($output_match | length) 1
        assert equal ((recall output $output_match.0.id).values) [1 2 3]

        let long_output = ((0..300 | each { "x" } | str join) + "deep-output-needle")
        recall __begin "produce long output"
        {data: $long_output} | recall __capture
        recall __finish
        assert equal (recall find "deep-output-needle" | length) 1

        recall __begin "let silent = true"
        recall __finish
        let silent = (recall find "let silent")
        assert equal ($silent.0.status) "no_output"

        recall pause
        recall __begin "this must not be stored"
        recall resume
        assert equal (recall find "must not be stored" | length) 0

        recall __begin "exit 98765"
        assert equal (recall find "exit 98765" | length) 0

        {
            storage: {
                max_size: "1 B"
                auto_prune: false
            }
        } | to toml | save --force $config_path

        let pruning = (recall prune --dry-run)
        assert ($pruning.outputs_pruned > 0) "dry-run identifies outputs over max_size"
        assert ((recall status).over_limit) "status reports storage over the configured limit"

        let pruned = (recall prune)
        assert ($pruned.outputs_pruned > 0) "prune removes old output payloads"
        assert not ((recall status).over_limit) "prune enforces max_size"
        assert ((recall | length) >= 3) "pruning retains command history metadata"

        {
            storage: {
                max_size: "1 B"
                auto_prune: true
            }
        } | to toml | save --force $config_path
        recall __begin "auto-pruned output"
        "larger than one byte" | recall __capture
        recall __finish
        assert equal ((recall find "auto-pruned output").0.status) "pruned"
        assert not ((recall status).over_limit) "auto pruning enforces max_size after capture"

        recall init
        let hook_count = ($env.config.hooks.pre_execution | length)
        recall init
        assert equal ($env.config.hooks.pre_execution | length) $hook_count
        assert ($env.RECALL_HOOKS_INSTALLED? | default false) "recall init installs hooks once"
    }

    rm --recursive $test_root
    print "All Recall tests passed."
}
