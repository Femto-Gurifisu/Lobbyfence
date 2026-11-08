# Security

LobbyFence runs as root on your router and changes its firewall, so security
problems matter. Thank you for reporting them privately.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead:
the repository's **Security** tab → **Report a vulnerability**. Include the
firmware (OpenWrt, FreshTomato, Asuswrt-Merlin or DD-WRT) and its version,
the LobbyFence version, and the steps to reproduce. A debug report
(*Debug* on the map page) helps; it hides passwords and API keys, but look
through it before you attach it.

Security fixes go into the latest version.

## How the web pages are protected

| Firmware | Who can use the page | Against other web sites (CSRF) |
| --- | --- | --- |
| OpenWrt | LuCI's login; LuCI's access rules allow only LobbyFence's own commands (`luci-app-lobbyfence.json`) | LuCI's session token |
| FreshTomato | the router's login | the router's per-session token (`http_id`) on every request |
| Asuswrt-Merlin | the router's login | requests go through the router's own add-on API |
| DD-WRT | a 128-bit random token that only *Status → My Page* (behind DD-WRT's login) hands out | the token, kept in the browser and never sent in an address |

On every firmware the router checks each request itself: only a fixed list of
commands is accepted, zone names and addresses are checked before use, and
text from outside (device names from DHCP, places from the address search,
zone names) is shown as text, never as HTML. DD-WRT's page listens on the LAN
address only and sends `Content-Security-Policy`, `X-Frame-Options: DENY`,
`X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`.

The map library (MapLibre GL JS) is loaded from a CDN and checked against a
SHA-256 hash before it runs. The OpenWrt installer downloads only over
`https://`.
