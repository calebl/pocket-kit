# The locally run app pattern

A small web app that runs on a machine you own and is used mostly from your
phone: a notebook, a tracker, a game you are building. No cloud host, no public
address. The machine and the phone are on the same private network (a VPN such
as Tailscale, WireGuard, ZeroTier or Nebula), and the app is reached at an https
address on that network.

The pattern below keeps each app small and the same shape as the others, so
setting up a new one is a checklist rather than a project. Tailscale is the
worked example throughout; any VPN that can give the machine an https address
works the same way.

## 1. Listen on localhost only

The app binds to `127.0.0.1`, never `0.0.0.0`. Nothing on the local network or
the internet can reach it directly; the only way in is through the VPN's https
address in step 2.

```sh
bin/rails server --binding 127.0.0.1 --port 3100
```

Give each app its own port and write it down in the app's env file (step 4).

## 2. Put the VPN's https address in front

The VPN terminates TLS with a real certificate for the machine's VPN name and
forwards plain http to the app on localhost.

With Tailscale (enable HTTPS certificates and MagicDNS for the tailnet first):

```sh
tailscale serve --bg --https=3100 http://127.0.0.1:3100
tailscale serve status
```

The app is now at `https://<machine>.<tailnet>.ts.net:3100` from any device on
the tailnet, and from nowhere else. `--bg` keeps the setting across restarts;
`tailscale serve --https=3100 off` removes it. Using the same number for the
https port and the local port keeps the two easy to match up.

With another VPN, run a reverse proxy (Caddy, nginx) bound to the VPN interface
with a certificate for the machine's VPN name, forwarding to `127.0.0.1:<port>`.

### Tell the app it is behind https

The app sees plain http from the proxy, so tell it the outside is https and
which host name to accept. In a Rails app's `config/environments/production.rb`:

```ruby
config.assume_ssl = true
config.force_ssl = true
config.hosts << ENV.fetch("APP_HOST")
```

## 3. A start script and a service

`templates/start.sh` loads the env file, checks the port is set and starts the
app on localhost. Copy it to `bin/start` in the app.

`templates/app.service` is a systemd user unit that runs `bin/start`, restarts
it on failure and starts it at login. Install it with:

```sh
cp templates/app.service ~/.config/systemd/user/myapp.service
systemctl --user daemon-reload
systemctl --user enable --now myapp
loginctl enable-linger "$USER"
```

On macOS, a launchd agent in `~/Library/LaunchAgents` does the same job.

## 4. Settings in an env file outside the repo

Secrets and machine-specific settings live in `~/.config/<app>/env`, one
`KEY=value` per line, mode `600`, never committed. `templates/app.env.example`
lists the usual ones: the port, the secret key, the VPN host name and the
feedback command. The repo can then be public without leaking anything, and a
fresh clone runs once the env file is in place.

## 5. A pinned header that stays put on a phone

On a phone the header (title, the few actions, the feedback button) should stay
at the top while the page scrolls, including when the on-screen keyboard is
open:

```css
.page-header {
  position: sticky;
  top: 0;
  padding-top: env(safe-area-inset-top);
  background: var(--page-background);
}
```

and in the layout:

```html
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
```

iPhone Safari shrinks the visible area when the keyboard opens without changing
the layout viewport, so a sticky header can slide out of view. pocket-kit's
next piece will pin the header to the visible viewport; until then, test the
header with the keyboard open (step 9).

## 6. A feedback button

Put pocket-kit's feedback button in the header so notes about the app can be
sent from the screen they are about. See the README for setup. The note goes to
a command you choose (a script that files an issue, appends to a file, sends a
message) together with the screen and what the device reports about itself.

pocket-kit's errors piece sends uncaught page errors and server exceptions to
a command the same way, grouping repeats, so a broken screen is noticed without
any outside service. Rails apps use the engine; other apps use the plain
browser script and, for Python, `python/pocket_kit.py`.

## 7. A home-screen icon and a manifest

Saved to the home screen, the app opens full screen like a native one. Add:

```html
<link rel="manifest" href="/manifest.json">
<link rel="apple-touch-icon" href="/icon-180.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#ffffff">
```

and `public/manifest.json`:

```json
{
  "name": "My App",
  "short_name": "My App",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#ffffff",
  "theme_color": "#ffffff",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
```

A 180×180 PNG with no transparency works best for the iPhone icon.

## 8. Deploy

Deploying is updating the checkout and restarting the service:

```sh
git pull
bundle install
bin/rails db:migrate        # if the app has a database
bin/rails assets:precompile # if it serves compiled assets
systemctl --user restart myapp
```

## 9. Checklist

Setting up a new app, and after each deploy:

- [ ] The app listens on `127.0.0.1:<port>` only: `ss -ltnp | grep <port>` shows `127.0.0.1`, not `0.0.0.0` or `*`.
- [ ] The VPN serves it: `tailscale serve status` lists `https://…:<port>` → `http://127.0.0.1:<port>`.
- [ ] From the phone, on the VPN, `https://<machine>.<tailnet>.ts.net:<port>` loads with a valid certificate.
- [ ] With the phone off the VPN, the address does not load.
- [ ] The env file is at `~/.config/<app>/env`, mode `600`, and nothing in it is in the repo.
- [ ] The service is enabled and comes back after a reboot: `systemctl --user status <app>`.
- [ ] The header stays at the top while scrolling and with the keyboard open.
- [ ] The feedback button sends a test note, and it arrives where the command puts it.
- [ ] Added to the home screen, the app opens full screen with its icon.
- [ ] Logs are clean after a page load: `journalctl --user -u <app> -n 50`.
