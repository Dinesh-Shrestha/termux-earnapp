# Termux EarnApp Setup

A community setup script for running EarnApp on Android through Termux and
udocker. It can also set up Termux:Boot, SSH, Cloudflared, udocker, and the
speedtest-go CLI.

## Install in Termux

The script is interactive. Download it, inspect it if you like, then run it as
the Termux app user; `sudo` is not used.

```sh
curl -fsSL https://termux-earnapp.dinesh29.com.np/earnapp-setup.sh -o earnapp-setup.sh
bash earnapp-setup.sh
```

Choose **6** for EarnApp, **7** to install speedtest-go, or **8** for all menu
options. speedtest-go is an on-demand CLI; run `speedtest-go` when you want to
test the device's internet connection. It does not run as a background service.
Open Termux:Boot once and disable battery optimization for Termux and
Termux:Boot if you want services to start after reboot.

## EarnApp logs

Follow the service log with:

```sh
tail -f "$PREFIX/var/log/sv/earnapp/current"
```

See [the logging guide](docs/earnapp-logs.md) for details.

## Source

The installer and project files are available in this public GitHub repository.
Review the script before running it, especially because setup can install
packages and enable background services.
