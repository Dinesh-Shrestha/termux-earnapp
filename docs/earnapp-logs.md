# EarnApp Service Logs

EarnApp runs under `termux-services` (runit). The service logger uses Termux's
`svlogd` helper, which stores the current log at:

```sh
$PREFIX/var/log/sv/earnapp/current
```

Follow new output with:

```sh
tail -f "$PREFIX/var/log/sv/earnapp/current"
```

The logger captures the container's standard output and error, including
startup failures and the foreground EarnApp process output. EarnApp's container
startup script suppresses output from its initial background `earnapp start`
command, so that command's messages are not present in this log.

The setup script creates or repairs the logger when it configures EarnApp. If
you add it manually, the service must have an executable `log/run` that invokes
`$PREFIX/share/termux-services/svlogger`.
