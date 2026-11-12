# Friend Radar

A phone-first web app: a 5-mile radar centered on you, friends who have added each other, waypoints friends can join, private home / school / work markers, an expandable street map, and four game-style overlays (Sonar, Parchment, Tactical, Pixel).

Files
- `index.html`: the whole app (no build step).
- `schema.sql`: the database tables and privacy rules for Supabase.

## Demo mode
With no keys set, the app runs in demo mode: sample friends, data saved only in that browser. Good for trying the look and feel.

## Going live (real accounts and real friends)
1. Create a free project at supabase.com.
2. Open the SQL editor, paste all of `schema.sql`, run it once.
3. In Project Settings > API, copy the Project URL and the `anon` public key.
4. Paste both into `CONFIG` near the top of the script in `index.html`.
5. Host `index.html` on any HTTPS host (Netlify Drop, Cloudflare Pages, GitHub Pages). Phones only give location to HTTPS pages.
6. Open the link, create an account, share your friend code.

Supabase asks new accounts to confirm their email by default. You can turn that off under Authentication while testing.

## How it works
- Location: the browser's GPS, sent to the `locations` table at most every 30 seconds or 25 meters. "Sharing on / Hidden" deletes your row so friends stop seeing you.
- Friends: each account gets an 8-character code. Entering a code sends a request; the other person accepts. Only accepted friends can read each other's location and waypoints (enforced in the database, not just the app).
- Waypoints: tap "Drop waypoint", tap the map, name it, pick how long it lasts. Friends can tap "I'm in".
- Places: home, school and work are stored per user and never shown to anyone else.
- Map: CARTO raster tiles of OpenStreetMap data, recolored per overlay. The app polls for updates every 8 seconds.

## Known limits
- A web page only tracks location while it is open on screen. Background tracking needs the native app.
- Street-name lettering is baked into the map images, so it keeps the map's own font. Overlay fonts apply to everything the app draws. Switching to vector tiles (MapLibre + Protomaps or MapTiler) would let street names change font per overlay.

## Path to iOS and Android
Wrap this same code with Capacitor: add `@capacitor/geolocation` plus a background-geolocation plugin, and push notifications for friend requests and waypoints. The data layer (`supabaseApi`) carries over unchanged.

## Before opening to the public
- A map tile plan with terms that cover a public app (the free CARTO tiles are for light use).
- Privacy policy, account deletion, block and report, and an age gate.
- Optional approximate-location mode and per-friend sharing controls.
- Rate limits on friend-code lookups.
