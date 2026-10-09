# Shared event-driven worker. Call tsg_worker PERIOD RETRY FUNCTION.
# Signals received during work or lock contention are not lost. A fixed
# two-second window coalesces bursts without postponing work indefinitely.
tsg_worker() {
    tsg_period=$1 tsg_retry=$2 tsg_action=$3
    tsg_limit=$tsg_period
    [ "$tsg_retry" -le "$tsg_limit" ] || tsg_limit=$tsg_retry
    tsg_delay=$tsg_retry tsg_stop=0 tsg_wake=0 tsg_sleeper='' tsg_debounce=0
    trap 'tsg_stop=1; [ -z "$tsg_sleeper" ] || kill "$tsg_sleeper" 2>/dev/null' TERM INT
    trap 'tsg_wake=1; [ "$tsg_debounce" = 1 ] || [ -z "$tsg_sleeper" ] || kill "$tsg_sleeper" 2>/dev/null' USR1 HUP
    while [ "$tsg_stop" = 0 ]; do
        tsg_wake=0
        "$tsg_action"; tsg_result=$?
        [ "$tsg_stop" = 0 ] || break
        if [ "$tsg_result" = 0 ]; then
            tsg_wait=$tsg_period tsg_delay=$tsg_retry
        elif [ "$tsg_result" = 75 ]; then
            # The configuration transaction owns the lock; try again soon.
            tsg_wait=2
        else
            tsg_wait=$tsg_delay
            tsg_delay=$((tsg_delay * 2))
            [ "$tsg_delay" -le "$tsg_limit" ] || tsg_delay=$tsg_limit
        fi
        if [ "$tsg_wake" = 0 ]; then
            sleep "$tsg_wait" & tsg_sleeper=$!
            # Cover a signal arriving between the condition and sleep setup.
            [ "$tsg_wake:$tsg_stop" = 0:0 ] || kill "$tsg_sleeper" 2>/dev/null
            wait "$tsg_sleeper" 2>/dev/null
            tsg_sleeper=''
        fi
        if [ "$tsg_wake" = 1 ] && [ "$tsg_stop" = 0 ]; then
            tsg_debounce=1
            sleep 2 & tsg_sleeper=$!
            # wait is interrupted by a trapped signal even without killing
            # sleep. Continue waiting for this window, rather than restarting it.
            while kill -0 "$tsg_sleeper" 2>/dev/null; do wait "$tsg_sleeper" 2>/dev/null; done
            tsg_sleeper='' tsg_debounce=0
        fi
    done
}
