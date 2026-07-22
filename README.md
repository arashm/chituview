# chituview

A read-only live terminal dashboard for Chitu-firmware resin 3D printers that
speak **SDCP V3.0.0** on the local network (UniFormation, Elegoo, and other
Chitu-based machines).

It discovers the printer over UDP, opens a WebSocket to stream live status, and
renders progress, layer counts, elapsed/remaining time, and error state in a
terminal UI. Press `c` to open the printer camera in an external player.

## Install

```bash
bundle install
gem build chituview.gemspec && gem install chituview-*.gem   # optional
```

## Usage

```bash
chituview                    # auto-discover on the LAN
chituview 192.168.50.133     # connect to a known IP
chituview --discover         # list printers and exit
chituview --timeout 5        # discovery timeout (seconds)
```

Keys: `c` open camera · `r` reconnect · `q` quit.

Camera requires one of `mpv`, `ffplay`, or `vlc` on your PATH.

## What it does not do

Read-only by design: it never pauses, resumes, stops, or deletes prints or files.
It only queries status/attributes and toggles the camera.

## License

MIT
