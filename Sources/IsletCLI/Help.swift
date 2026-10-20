/// `--help` texts.
enum Help {
    static func topic(_ name: String) -> String? {
        switch name {
        case "timer", "timers": timer
        case "stopwatch", "sw", "pomodoro", "pomo", "awake", "caffeinate", "alarm": clock
        case "activity": activity
        case "status", "list", "open": main
        default: nil
        }
    }

    static let main = """
    islet: control Islet, the Dynamic Island in your Mac's notch.

    Usage:
      islet <command> [options]
      islet "tea 4m"                  anything the island's command bar understands

    Clock:
      islet timer 25m [--label Tea]   start a timer (also: islet timer start 25m)
      islet timer list
      islet timer pause|resume|cancel [--id ID]
      islet timer add 1m [--id ID]    without --id: the timer ending soonest
      islet stopwatch [start|pause|lap|reset]
      islet pomodoro [start|pause|resume|skip|stop]
      islet awake [2h|stop]           keep the Mac awake (no duration: until stopped)
      islet alarm 7:30 [--label Gym] [--days mon,tue|weekdays|weekends|daily]

    Custom live activities (scripts, builds, Claude Code hooks):
      islet activity set --id ID --title TEXT [--subtitle TEXT] [--symbol NAME] [--tint COLOR]
                         [--progress 0.4|40%|indeterminate|none] [--ends-in 5m] [--text 3/9]
                         [--action "Logs=https://..."] [--alert] [--ttl 30m]
      islet activity end --id ID [--state done|failed|cancelled] [--title TEXT] [--subtitle TEXT]
      islet activity --help           every option

    Other:
      islet status                    running activities
      islet open [live|shelf|clock]   open the island (clock: the Clock app)

    Options:
      --json                          print the raw JSON reply
      -q, --quiet                     print nothing on success (hooks: errors still go to stderr)
      --no-launch                     don't start Islet if it isn't running
      -h, --help                      help (also: islet <command> --help)
      --version

    Durations: 25 (minutes), 25m, 1h30, 90s, 5:00.
    Exit status: 0 done, 1 Islet refused the command, 2 usage error, 3 Islet not reachable.
    In Claude Code hooks, end commands with "|| true": exit status 2 means "block" there.
    """

    static let timer = """
    islet timer 25m [--label Tea]          start a timer; extra words are the label: islet timer 4m green tea
    islet timer start 25m [--label Tea]    same
    islet timer list                       running timers (also: islet timer)
    islet timer pause [--id ID]            without --id: the timer ending soonest
    islet timer resume [--id ID]
    islet timer cancel [--id ID]
    islet timer add 1m [--id ID]           add time

    Durations: 25 (minutes), 25m, 1h30, 1h30m, 90s, 5:00, 1:30:00.
    """

    static let clock = """
    islet stopwatch [start|pause|toggle|lap|reset]     no verb: start
    islet pomodoro [start|pause|resume|skip|stop]      no verb: start
    islet awake                                        keep the Mac awake until stopped
    islet awake 2h                                     ... for 2 hours
    islet awake stop
    islet alarm 7:30 [--label Gym] [--days mon,tue]    also 19:05, 7pm, 7h30
                                                       --days: mon...sun, weekdays, weekends, daily
                                                       Alarms only ring while the Mac is awake.
    """

    static let activity = """
    islet activity set --id ID [options]
      Starts or updates a live activity in the island. What an update omits is kept. Faster than 4 updates
      per second, updates are merged.

      --id ID              1 to 32 letters, digits, '.', '_' or '-'
      --title TEXT         up to 40 characters; required to start
      --subtitle TEXT      up to 60 characters ('' clears it)
      --symbol NAME        SF Symbol name, e.g. hammer (unknown names show app.badge)
      --tint COLOR         orange, blue, green, red, yellow, purple, pink, cyan, white, gray or #RRGGBB
      --progress VALUE     0...1, a percentage (40%), indeterminate (also: --indeterminate), or none to
                           remove the ring and the countdown
      --ends-in DURATION   countdown ring and time, e.g. 5m   (or --ends-at 14:30)
      --text TEXT          up to 6 characters next to the ring, e.g. 3/9 ('' clears it)
      --action TITLE=URL   button opening an http(s) URL or a file (a path works); at most 2
      --alert              show the alert card; the activity ranks first until the next update
      --ttl DURATION       ends after this long without updates: 15m by default, 8h at most

      Progress, indeterminate and the countdown form one ring: setting any of them replaces the others.

    islet activity end --id ID [--state done|failed|cancelled] [--title TEXT] [--subtitle TEXT]
      done and failed show a 4-second alert, then the activity ends. cancelled (the default) ends it quietly.
      With --title, done/failed still show their alert when the activity already expired.

    islet activity list                    same as islet status

    Example:
      islet activity set --id build --title Build --subtitle Compiling --symbol hammer --tint blue --progress 0
      islet activity set --id build --progress 40%
      islet activity end --id build --state done --subtitle "Built in 42 s"
    """
}
