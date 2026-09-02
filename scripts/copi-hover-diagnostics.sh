#!/bin/zsh
set -euo pipefail

readonly bundle_id="com.jos.copi"
readonly logs_dir="${HOME:?}/Library/Application Support/Copi/Logs"

usage() {
    print "Usage: $0 <enable|disable|status|report|capture|sample [seconds]>"
    print "  enable   Enable privacy-filtered JSONL logging for the next Copi launch"
    print "  disable  Disable new JSONL events for the next Copi launch"
    print "  status   Show the setting and managed log files"
    print "  report   Summarize only hover/layout/stall metadata as JSON"
    print "  capture  Save the current metadata-only report under /tmp"
    print "  sample   Invasive: collect process stacks; may pause Copi while attached"
}

managed_logs() {
    [[ -d "$logs_dir" ]] || return 0
    /usr/bin/find "$logs_dir" -maxdepth 1 -type f -name 'copi-debug-*.jsonl' -print
}

case "${1:-}" in
    enable)
        /usr/bin/defaults write "$bundle_id" debugLoggingEnabled -bool true
        print "Debug logging enabled for the next Copi launch. Relaunch and unlock Copi before reproducing."
        ;;
    disable)
        /usr/bin/defaults write "$bundle_id" debugLoggingEnabled -bool false
        print "Debug logging disabled for the next Copi launch. Existing files were not removed."
        ;;
    status)
        enabled=$(/usr/bin/defaults read "$bundle_id" debugLoggingEnabled 2>/dev/null || print "0")
        print "debugLoggingEnabled=$enabled"
        print "logsDirectory=$logs_dir"
        managed_logs
        ;;
    report)
        log_files=("$logs_dir"/copi-debug-*.jsonl(N))
        if (( ${#log_files[@]} == 0 )); then
            print -u2 "No Copi diagnostic logs found in $logs_dir"
            exit 1
        fi
        /usr/bin/jq -s '
            def field($key):
                ([.fields[]? | select(.key == $key) | .value][0] // null);
            def number($key):
                ((field($key) // "0") | tonumber? // 0);
            [ .[]
              | select(
                    .name == "hoverTargetChanged"
                    or .name == "hoverScopeCommitted"
                    or .name == "hoverResultsMaterialized"
                    or .name == "overlayLayoutSlow"
                    or .name == "mainThreadStallDetected"
                    or .name == "hoverDiagnosticSummary"
                )
            ] | sort_by(.timestamp) as $events
            | {
                eventCount: ($events | length),
                sessions: ($events | map(.correlation.overlaySessionID // empty) | unique),
                counts: (reduce $events[] as $event ({};
                    .[$event.name] = ((.[$event.name] // 0) + 1))),
                worstMainQueueDelayMilliseconds: (
                    [$events[] | select(.name == "mainThreadStallDetected")
                     | number("mainQueueDelayMilliseconds")] | max // 0
                ),
                worstLayoutMilliseconds: (
                    [$events[] | select(.name == "overlayLayoutSlow")
                     | number("durationMilliseconds")] | max // 0
                ),
                summaries: [
                    $events[] | select(.name == "hoverDiagnosticSummary") | {
                        timestamp,
                        overlaySessionID: .correlation.overlaySessionID,
                        pointerEvents: number("pointerEventCount"),
                        targetTransitions: number("targetTransitionCount"),
                        scopeCommits: number("scopeCommitCount"),
                        layoutPasses: number("layoutPassCount"),
                        slowLayoutPasses: number("slowLayoutPassCount"),
                        maximumLayoutMilliseconds: number("maximumLayoutMilliseconds")
                    }
                ],
                stalls: [
                    $events[] | select(.name == "mainThreadStallDetected") | {
                        timestamp,
                        overlaySessionID: .correlation.overlaySessionID,
                        scope: field("scope"),
                        mainQueueDelayMilliseconds: number("mainQueueDelayMilliseconds"),
                        pointerEvents: number("pointerEventCount"),
                        targetTransitions: number("targetTransitionCount"),
                        scopeCommits: number("scopeCommitCount"),
                        layoutPasses: number("layoutPassCount"),
                        slowLayoutPasses: number("slowLayoutPassCount")
                    }
                ],
                timeline: [
                    $events[-50:][] | {
                        timestamp,
                        name,
                        level,
                        overlaySessionID: .correlation.overlaySessionID,
                        scope: field("scope"),
                        previousScope: field("previousScope"),
                        durationMilliseconds: number("durationMilliseconds"),
                        mainQueueDelayMilliseconds: number("mainQueueDelayMilliseconds"),
                        pointerEvents: number("pointerEventCount"),
                        targetTransitions: number("targetTransitionCount"),
                        scopeCommits: number("scopeCommitCount"),
                        resultCount: number("resultCount"),
                        layoutPasses: number("layoutPassCount"),
                        slowLayoutPasses: number("slowLayoutPassCount")
                    }
                ]
            }
        ' "${log_files[@]}"
        ;;
    capture)
        timestamp=$(/bin/date -u +%Y%m%dT%H%M%SZ)
        output="/tmp/copi-hover-${timestamp}.report.json"
        "$0" report > "$output"
        print "$output"
        ;;
    sample)
        duration="${2:-15}"
        if [[ ! "$duration" =~ '^[1-9][0-9]*$' ]]; then
            print -u2 "Sample duration must be a positive integer number of seconds."
            exit 2
        fi
        process_id=$(/usr/bin/pgrep -x Copi | /usr/bin/head -n 1)
        if [[ -z "$process_id" ]]; then
            print -u2 "Copi is not running."
            exit 1
        fi
        timestamp=$(/bin/date -u +%Y%m%dT%H%M%SZ)
        output="/tmp/copi-hover-${timestamp}.sample"
        print -u2 "Warning: /usr/bin/sample is invasive and may visibly pause Copi. Do not run it during the first reproduction pass."
        /usr/bin/sample "$process_id" "$duration" 1 -mayDie -file "$output"
        if [[ ! -s "$output" ]]; then
            print -u2 "sample did not produce $output; check Terminal developer-tool permissions."
            exit 1
        fi
        print "$output"
        ;;
    *)
        usage
        exit 2
        ;;
esac
