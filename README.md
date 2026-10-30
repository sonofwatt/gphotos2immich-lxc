# gphotos2immich-lxc

A Proxmox VE helper script, in the style of the tteck scripts, that creates an
LXC running [gPhotos2Immich](https://github.com/warreth/gPhotos2Immich). It
copies a public Google Photos shared album into Immich on a schedule, so the
photos get Immich's face detection, search and the rest.

No Docker: the app is built from source with Go and runs as a systemd service.

## What it creates

- Unprivileged Debian 13 LXC: 1 CPU, 2 GB RAM (plus 512 MB swap), 4 GB disk,
  DHCP on `vmbr0`, starts at boot. Advanced settings change any of these.
- `/opt/gphotos2immich/gphotos2immich`, built from release `v1.7.4` (the
  version whose code was reviewed), owned by root and run as the unprivileged
  `gphotos2immich` user.
- `/opt/gphotos2immich/config.json`: the album link, its name in Immich and the
  sync interval. It holds no secrets. Photos only by default (`skipVideos`);
  Advanced settings can include videos.
- `/etc/gphotos2immich.env` (root only, mode 600): the Immich API key and URL,
  plus `DISABLE_WEBUI=true`.
- `gphotos2immich.service`, sandboxed so it can only write to
  `/opt/gphotos2immich/data` (its record of what it has already uploaded).
- `update-gphotos2immich [tag]`: rebuilds at a release tag, newest by default
  (source in `install/update-gphotos2immich.sh`).

The web UI is off. It has no password and serves the whole config, API key
included, to anyone on the network who asks.

## Before you run it

1. In Immich, create an API key with these permissions:
   `asset.read`, `asset.upload`, `album.create`, `album.read`, `album.update`,
   `albumAsset.create`, `user.read`.
2. Check the album link opens in a private browser window (only public shared
   links work).

## Run it

In the Proxmox host's shell, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sonofwatt/gphotos2immich-lxc/main/ct/gphotos2immich.sh)"
```

Or from a checkout: `bash ct/gphotos2immich.sh`.

It asks for the Immich API URL (for example `http://192.168.1.10:2283/api`),
the API key and the album link, then creates the container, builds the app,
checks the key against Immich and starts the service.

## Day to day

```bash
pct exec <CTID> -- journalctl -u gphotos2immich -f
pct exec <CTID> -- /usr/local/bin/update-gphotos2immich
pct exec <CTID> -- /usr/local/bin/update-gphotos2immich v1.7.4
```

`pct exec` runs commands without a login shell, so `/usr/local/bin` may not be
on its PATH; give the full path as above.

To change the album or interval, edit `/opt/gphotos2immich/config.json` in the
container and run `systemctl restart gphotos2immich`. To rotate the key, edit
`/etc/gphotos2immich.env` and restart.

## Things to know

- The first sync copies the whole album and can take hours for a
  large album. Later syncs only upload what is new.
- Google serves shared albums as re-compressed copies, so photos already in
  Immich from a phone will show up twice. Immich's duplicate review cleans
  those up.
- The app holds each item in memory while it uploads, several at a time, so
  512 MB is not enough. 2 GB is the default.
- `update-gphotos2immich` applies one local patch when it builds: skip videos
  *before* downloading them. Upstream v1.7.4 downloads each whole video into
  memory and only then checks `skipVideos`, so an album with long videos gets
  the service OOM-killed in a loop. The patch is skipped if upstream already
  does this.
- The app scrapes Google's shared-album pages. A change on Google's side can
  break it until the app is updated.

## License

MIT for these scripts. gPhotos2Immich itself is AGPL-3.0 and is downloaded
from its own repository at install time.
