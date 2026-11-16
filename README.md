# Termux EarnApp Setup

A community setup script for running EarnApp on Android through Termux and
udocker. It can also set up Termux:Boot, SSH, Cloudflared, udocker, the
speedtest-go CLI, and an opt-in auto-recovery job.

## Install in Termux

The script is interactive. Download it, inspect it if you like, then run it as
the Termux app user; `sudo` is not used.

```sh
curl -fsSL https://termux-earnapp.dinesh29.com.np/earnapp-setup.sh -o earnapp-setup.sh
bash earnapp-setup.sh
```

Choose **6** for EarnApp, **7** to install speedtest-go, **8** to schedule the
auto-recovery job, or **9** for all menu options. speedtest-go is an on-demand
CLI; run `speedtest-go` when you want to test the device's internet connection.
It does not run as a background service. Open Termux:Boot once and disable
battery optimization for Termux and Termux:Boot if you want services to start
after reboot.

Whenever setup configures the boot/service layer (SSH, Cloudflared, EarnApp,
the recovery job, or the boot component itself), it acquires a Termux wake lock
immediately and adds `termux-wake-lock` to the Termux:Boot script so the lock
returns after reboot. Components that do not start a service (base, udocker,
speedtest-go) do not take a wake lock.

## Auto-recovery after Android kills Termux

Android may kill Termux's process when memory runs low. The optional recovery
job asks `termux-job-scheduler` to run the Termux:Boot start script again every
15–30 minutes, so the supervisor and its services come back without opening the
app. Enable it from the menu (**8**) or with `--recovery`; it is also part of
`--all` but not part of `--earnapp`.

This is best effort, not a guarantee:

- It needs the **Termux:API** app from F-Droid in addition to the `termux-api`
  package. The setup detects it through its data directory
  (`/data/data/com.termux.api`), which is visible because Termux:API shares
  Termux's UID. Plain `pm list packages` is filtered by Android and is not used.
- A missing Termux:API app fails immediately with install instructions. If the
  app is installed but force-stopped, `termux-job-scheduler` hangs while waiting
  for it; the setup caps that call at 10 seconds, warns that the job was **not**
  scheduled, and exits non-zero. Open Termux:API, then re-run `--recovery`.
- It reuses `~/.termux/boot/start-services`, so run `--boot` first.
- The job is scheduled with `--network none`. That is offline-safe, but it also
  makes `termux-job-scheduler --pending` and `--cancel` unusable (an upstream
  Termux:API bug crashes while formatting the result, after the job is already
  scheduled). Silence after scheduling is expected.
- On Android 9+ that bug also raises a notification titled `Error in
  ResultReturner` with a `NullPointerException` at
  `JobSchedulerAPI.formatJobInfo`. It is harmless: `schedule()` runs first, so
  job 1001 is registered before the crash and only the confirmation message is
  lost. Ignore the notification; it is not a scheduling failure.
- Force-stopping **Termux:API** cancels job 1001, and persisted jobs do not come
  back automatically. Force-stopping Termux itself does not cancel the job, and
  that is the case the job recovers from. Vendor "cleaner" apps or disabling the
  job can also cancel it. Verify and cancel it over ADB instead:
  ```sh
  adb shell cmd jobscheduler get-job-state com.termux.api 1001
  adb shell cmd jobscheduler cancel com.termux.api 1001
  ```
- Without ADB there is no in-app listing: with `--network none`, every
  `termux-job-scheduler` query (`--pending`, `--cancel`, `--cancel-all`) hits the
  same `formatJobInfo` crash before printing. To prove the job runs, force-stop
  Termux from Android Settings, wait 15–30 minutes (Doze can delay it), then
  connect over SSH; if `sshd` answers, the job fired and restarted the services.

## EarnApp logs

Follow the service log with:

```sh
tail -f "$PREFIX/var/log/sv/earnapp/current"
```

See [the logging guide](docs/earnapp-logs.md) for details.

## Service restarts

Restarting EarnApp with `sv restart earnapp`, `sv down earnapp`, or
`sv up earnapp` only signals EarnApp's own process tree. Other services running
under udocker keep running. Cleanup refuses `runsv`/`runsvdir`, pid 1, and its
own ancestors, so a stale pid file cannot take down the supervisor.

The setup starts the termux-services supervisor itself instead of sourcing the
profile hook. Sourcing it runs `service-daemon start` even when a supervisor is
already running, and the duplicate's short-lived `runsv` children fight the
originals over `supervise/`. Re-run the EarnApp setup after upgrading this
script so an existing service picks up the scoped cleanup files.

APT package transactions can drop a service's `down` marker and silently disable
it. The setup installs APT pre/post hooks that snapshot enabled services before
a transaction and re-enable only those that went down during it. The boot script
also runs `service-repair.sh boot` to finish an interrupted transaction. Both
only touch services listed in `$PREFIX/var/lib/earnapp-setup/pending-services`,
so a deliberate `sv down <service>` is left alone. Inspect it with
`service-repair.sh status`.

## Source

The installer and project files are available in this public GitHub repository.
Review the script before running it, especially because setup can install
packages and enable background services.
