# Auxcord.org Bug Report

Static audit completed on March 30, 2026.

Scope reviewed:

- `server.rb`
- `spotify.rb`
- `sonos.rb`
- `db.rb`
- all ERB templates under `views/`
- all JS/CSS partials under `views/js/` and `views/css/`

Notes:

- This report is from source review plus a few local sanity checks (`ruby -c` on the Ruby files).
- I did not run the full app end-to-end in this environment because the required Ruby/Bundler setup is not available here.
- External API behavior below is only cited where it materially affects a bug:
  - Sonos subscription/callback docs: https://docs.sonos.com/docs/subscribe
  - Sonos auth/token docs: https://docs.sonos.com/docs/authorize
  - RSpotify token refresh docs: https://github.com/guilhermesad/rspotify

## Critical Findings

### 1. Queue state only exists in process memory

Files:

- `server.rb:9-11`
- `server.rb:54-70`
- `server.rb:389-407`
- `server.rb:530`
- `server.rb:661-665`
- `spotify.rb:11-21`
- `spotify.rb:87-118`
- `sonos.rb:14-18`
- `sonos.rb:43-45`

What is wrong:

- Guest queue state is held in Ruby memory only:
  - `Spotify#queued_songs`
  - `Spotify#past_songs`
  - `Sonos#currently_playing_guest_wished_song`
  - `Sonos#current_item_id`
  - cached playback metadata
- The database only persists auth tokens and a few Sonos settings.

Why it causes the reported symptoms:

- Any process restart, deploy, crash, or horizontal scaling event wipes the queue and playback state.
- After a restart, the app forgets which guest song is playing and what should play next, so queued songs can disappear, duplicates can be allowed again, and callback-driven queue advancement can stop.
- In a multi-process deployment, one request can queue a song into process A while the Sonos callback lands on process B, which has an empty queue. That will look exactly like “the song queued successfully, but never played.”

### 2. Queueing is race-prone and not synchronized

Files:

- `server.rb:364-412`
- `server.rb:480-580`
- `spotify.rb:87-118`

What is wrong:

- Queue mutations happen from multiple request threads plus callback handling with no mutex or transactional protection.
- The code performs multi-step read/check/write sequences on shared arrays and flags:
  - duplicate check
  - `queued_songs << song`
  - `queued_songs.shift`
  - `past_songs << next_song`
  - `currently_playing_guest_wished_song = ...`
- The first guest song also spawns a detached `Thread.new` to enqueue on Sonos.

Why it causes the reported symptoms:

- Two guests submitting at nearly the same time can both pass the duplicate check, both see `currently_playing_guest_wished_song == false`, and both start Sonos queue work.
- `Spotify#add_next_song_to_sonos_queue!` clears the playlist and shifts from the queue before the Sonos insert succeeds, so concurrent calls can reorder songs, drop songs, or queue the wrong song next.
- This is a direct explanation for intermittent “sometimes it works, sometimes it doesn’t” queue failures.

### 3. The app reports success before Sonos queueing actually succeeds

Files:

- `server.rb:404-411`
- `spotify.rb:92-118`

What is wrong:

- On the first guest request, the server immediately returns `success: true` and `position: 0`.
- The actual Sonos insert happens later on a background thread.
- There is no join, no error capture, and no retry.

Why it causes the reported symptoms:

- Users can get a success popup even when:
  - the Sonos favorite lookup fails
  - the Sonos insert fails
  - the Spotify playlist update fails
  - the auth token is stale
- The UI says “it will be played next” even though nothing was actually inserted into the Sonos queue.

### 4. Failed Sonos inserts permanently lose songs and can wedge the queue

Files:

- `server.rb:404-407`
- `spotify.rb:94-118`

What is wrong:

- `Spotify#add_next_song_to_sonos_queue!` does this in order:
  1. clears the playlist
  2. `shift`s the next song out of memory
  3. appends it to `past_songs`
  4. adds it to the Spotify playlist
  5. looks up the Sonos favorite
  6. sends the Sonos `INSERT_NEXT`
  7. removes the track from the playlist again
- If any step after `shift` fails, the song is already gone from the real queue and marked as “past.”
- In the route, `currently_playing_guest_wished_song` is set to `true` before the background queue operation succeeds.

Why it causes the reported symptoms:

- A failed first insert can leave the system thinking a guest song is active even though none was queued on Sonos.
- Later guest requests then go into the in-memory array and wait for a callback that never arrives.
- From the user’s point of view: the first song “queued” but never plays, and future songs pile up forever.

### 5. Sonos callback handling violates Sonos’s timing guidance

Files:

- `server.rb:480-580`

What is wrong:

- Sonos documents that callback handlers should return `200` quickly, ideally within 1 second, and defer lengthy work.
- This handler does the opposite before responding:
  - parses and logs the full JSON body
  - may call `play_music!`
  - may call `add_next_song_to_sonos_queue!`
  - may hit Spotify twice via `find_song`
  - may update playback caches
- Only after all of that does it send `status 200`.

Why it causes the reported symptoms:

- Slow Spotify/Sonos API calls can push the callback over Sonos’s timeout window.
- Sonos may retry or drop events.
- Since queue advancement depends on these callbacks, dropped playback events translate directly into “next queued song never started.”

### 6. Sonos subscriptions are never renewed and are not recreated for new groups

Files:

- `sonos.rb:46-55`
- `server.rb:312-322`
- `server.rb:486-487`

What is wrong:

- The app subscribes to playback and playback metadata only once during `Sonos#initialize`.
- Sonos documents that subscriptions live for a maximum of three days and that clients must resubscribe when groups move or change.
- When the host changes `group_to_use`, the code updates the group ID and restarts playback, but never subscribes the new group.

Why it causes the reported symptoms:

- After a speaker-group change, callbacks for the new group never arrive.
- The callback router only matches events whose `X-Sonos-Target-Value` equals the current `group_to_use`, so old-group callbacks are ignored once the group changes.
- After a few days, even unchanged groups can silently stop delivering events if the subscription expires.
- Result: queue advancement stops, playback state gets stale, and songs stop chaining correctly.

## High Findings

### 7. Background maintenance threads die permanently on the first exception

Files:

- `server.rb:57-70`
- `sonos.rb:87-99`

What is wrong:

- The two long-lived background loops have no per-user rescue.
- Any exception from one Sonos account kills the entire thread.

Why it causes the reported symptoms:

- One transient Sonos API failure can permanently stop:
  - automatic volume enforcement
  - playback enforcement
  - cache refreshes for groups/favorites
- After that, the host dashboard uses stale group/favorite data and playback drift is no longer corrected.

### 8. Logging out deletes DB rows but leaves live in-memory sessions active

Files:

- `server.rb:327-338`
- `server.rb:651-658`

What is wrong:

- `/logout` deletes database rows and clears `session[:user_id]`, but it does not remove the user’s objects from `GlobalState[:spotify_instances]` and `GlobalState[:sonos_instances]`.

Why it causes the reported symptoms:

- Existing invite links can keep working until the process restarts because the guest endpoints resolve from the in-memory hashes, not the DB.
- The deleted Sonos instance may also stay in the background loops and callback router.
- This is both a security problem and a source of confusing “I logged out but the old party still sort of works” behavior.

### 9. Invalid or stale guest links crash instead of failing safely

Files:

- `server.rb:345-360`
- `server.rb:364-389`
- `server.rb:619-631`

What is wrong:

- Guest routes assume `spotify_instances[user_id]` and `sonos_instances[user_id]` exist.
- There is no nil guard before calling `party_playlist`, `queued_songs_json`, or `search_for_song`.

Why it causes the reported symptoms:

- Any stale QR code, deleted party, restarted process, or guessed URL can produce `NoMethodError` and a 500.
- To a guest this shows up as “general breakage” or “the queue page is broken.”

### 10. Bad/removed Spotify track IDs crash the queue endpoint

Files:

- `server.rb:379-382`
- `spotify.rb:71-84`

What is wrong:

- `spotify_instance.find_song` explicitly rescues and returns `nil`.
- The route immediately calls `song_to_queue.id.to_s` during duplicate checking with no nil guard.

Why it causes the reported symptoms:

- If Spotify search returns a track that later becomes unavailable, or the client submits a bad ID, the queue request 500s.
- Guests see a generic failure instead of a recoverable error message.

### 11. Sonos OAuth state is hardcoded and never validated

Files:

- `server.rb:87-94`
- `server.rb:418-476`

What is wrong:

- The Sonos auth URL always uses `state=TESTSTATE`.
- The callback does not verify `state` at all.

Why it causes the reported symptoms:

- This is a standard OAuth CSRF/account-mixup bug.
- A malicious or stale auth redirect can attach the wrong Sonos household to the current browser session.
- In practice that can manifest as “my host dashboard controls the wrong speakers” or “my session suddenly broke after reauth.”

### 12. Sonos callbacks are accepted without signature verification

Files:

- `server.rb:480-580`

What is wrong:

- Sonos sends `X-Sonos-Event-Signature` and recommends verifying it.
- The app trusts any POST body sent to `/callback`.

Why it causes the reported symptoms:

- Anyone who can hit that endpoint can spoof playback events and trigger queue advancement, forced resume, or state corruption.
- Even accidental/bogus traffic can mutate `current_item_id` and the guest-song flag.

### 13. CSRF protection is missing on host-control endpoints

Files:

- `server.rb:285-325`
- `server.rb:327-339`

What is wrong:

- The host control route accepts state-changing POSTs with only the session cookie.
- `/logout` is a destructive GET.
- There are no CSRF tokens and no origin/referrer checks.

Why it causes the reported symptoms:

- A logged-in host can be tricked into:
  - pausing/resuming playback
  - changing volume
  - skipping songs
  - changing groups
  - deleting all stored auth tokens via `/logout`
- This is an obvious security issue.

### 14. Spotify token refresh is not persisted

Files:

- `spotify.rb:23-27`
- `spotify.rb:129-162`

External reference:

- RSpotify documents automatic refresh, but also explicitly recommends persisting refreshed credentials via `access_refresh_callback` or `to_hash`.

What is wrong:

- `spotify_user` rebuilds a fresh `RSpotify::User` object from the DB row on every call.
- The stored JSON is only written once during initial auth.
- No `access_refresh_callback` is configured, and refreshed credentials are never written back to `Db.spotify_tokens`.

Why it causes the reported symptoms:

- Once the original Spotify access token ages out, the app repeatedly reconstructs users from stale credentials.
- Best case: every request has to refresh again, adding latency and fragility.
- Worst case: if Spotify changes refresh-token behavior or the stale token data is no longer accepted, playlist/search calls start failing and queueing breaks.

### 15. Duplicate Spotify auth rows are possible and the code reads an arbitrary one

Files:

- `db.rb:37-46`
- `spotify.rb:29-33`
- `spotify.rb:159-162`
- `server.rb:590-600`

What is wrong:

- `spotify_tokens.user_id` is not unique.
- Each Spotify auth callback inserts a new row.
- Reads use `.where(user_id: user_id).first`, which is not deterministic across duplicates.

Why it causes the reported symptoms:

- Reconnecting Spotify can leave old token rows behind.
- The app may later pick a stale row with an old playlist ID or expired credentials.
- That produces intermittent auth failures that are hard to reproduce.

### 16. `primary_household` rescue path returns the wrong type

Files:

- `sonos.rb:169-188`

What is wrong:

- The normal path returns a household ID string.
- The rescue path stores `households.first`, which is a household hash, not its ID.

Why it causes the reported symptoms:

- After any exception during household enumeration, later API paths interpolate a hash into URLs like `/households/#{primary_household}/favorites`.
- That can break all Sonos API requests for that user until restart/re-auth.

## Medium Findings

### 17. Host group changes made outside auxcord can break the current selection

Files:

- `sonos.rb:36-41`
- `server.rb:174-181`
- `server.rb:224-232`

What is wrong:

- The code repairs an invalid group only during `Sonos#initialize`.
- If the selected Sonos group disappears later due to regrouping in the Sonos app, the live session keeps the stale `group_to_use`.

Why it causes the reported symptoms:

- Playback/control requests start targeting a dead group ID.
- `party_data` can also blow up when it does `find { ... }['name']` and `find` returns `nil`.
- This produces broken dashboards and failed playback control after speaker regrouping.

### 18. Search autocomplete does too much work and lacks failure guards

Files:

- `server.rb:630-648`

What is wrong:

- For every search request, the endpoint fetches `audio_features` for every returned track.
- There is no rescue if `audio_features` is nil or if one of those requests fails/rate-limits.

Why it causes the reported symptoms:

- Autocomplete gets slow because one text search fans out into many extra Spotify calls.
- One bad track can fail the whole response and break the search UI.
- Under load, this increases the chance of Spotify errors that the frontend reports only as “something went wrong.”

### 19. Search text is not URL-encoded on the guest page

Files:

- `views/js/_queue_song.js.erb:5-7`

What is wrong:

- The code concatenates raw input directly into `?song_name=` instead of using `encodeURIComponent`.

Why it causes the reported symptoms:

- Searches containing `&`, `#`, `%`, `+`, or `?` can be truncated or malformed.
- Guests can get empty or wrong results even though the song exists.

### 20. Host dashboard polling uses synchronous XHR

Files:

- `views/js/_party.js.erb:147-159`

What is wrong:

- `xhr.open("GET", "/party.json", false)` is a synchronous request.

Why it causes the reported symptoms:

- Every 2.5 seconds the browser can block the main thread while waiting for the server.
- When the server is slow, the whole host UI freezes or becomes visibly janky.
- This makes the dashboard feel broken exactly when the backend is already under stress.

### 21. Clicking the groups button throws because the target element is commented out

Files:

- `views/party.erb:53-57`
- `views/js/_party.js.erb:116-126`

What is wrong:

- The JS expects an element with `id="groups-div"`.
- The template has that element commented out.

Why it causes the reported symptoms:

- Clicking the groups button dereferences `null.style`.
- One host interaction can break the rest of the page’s JS execution.

### 22. Pause/play icon refresh logic can hide both icons

Files:

- `views/js/_party.js.erb:18`
- `views/js/_party.js.erb:74-79`

What is wrong:

- `refreshUI` only hides one icon based on `party_on`; it never explicitly shows the other one.
- After a few state transitions, both icons can end up hidden.

Why it causes the reported symptoms:

- The host sees a blank or misleading play/pause button even though the underlying route is still being called.

### 23. Login page JS crashes when `#meme-carousel` is absent

Files:

- `views/login.erb:83-154`
- `views/js/_login.js.erb:2-8`

What is wrong:

- `_login.js.erb` always assumes `document.getElementById('meme-carousel')` exists.
- The template only renders that element in one branch of the page.

Why it causes the reported symptoms:

- On the “connect Spotify” step, or any other state where the carousel is omitted, the script throws before doing anything else.
- It is a visible frontend bug and a sign the page was never exercised in that state.

### 24. Initial host page rendering re-runs `party_data` and duplicates API work

Files:

- `server.rb:143-150`
- `views/js/_party.js.erb:137`

What is wrong:

- The route already computes `pd = party_data`.
- The JS partial then calls `party_data` again during template rendering.

Why it causes the reported symptoms:

- Each page load doubles the Sonos/Spotify work for the same state snapshot.
- That increases load, latency, and the chance of timing-sensitive failures on an already fragile path.

## Security Findings

### 25. The app renders third-party metadata without escaping

Files:

- `views/queue_song.erb:11-13`
- `views/queue_song.erb:37`
- `views/add_playlist_to_favs.erb:13`
- `views/js/_party.js.erb:5`
- `views/js/_party.js.erb:15`
- `views/js/_party.js.erb:19`
- `views/js/_party.js.erb:36`
- `views/js/_queue_song.js.erb:13-17`

What is wrong:

- Server-rendered ERB output is inserted with raw `<%= ... %>`.
- Client-side code uses `innerHTML` and string-built HTML for Spotify/Sonos data.
- Track names, artist names, playlist names, and group names are treated as trusted HTML.

Why it causes the reported symptoms:

- This is an XSS risk. A maliciously crafted third-party metadata value can inject markup/script into host or guest pages.
- Even if exploitation is rare, it is a real trust-boundary problem and should be treated as one.

### 26. Invite links can outlive logout because access is keyed to memory, not the DB

Files:

- `server.rb:345-360`
- `server.rb:364-412`
- `server.rb:327-338`

What is wrong:

- Guest routes resolve parties from the in-memory instance hashes, not from current DB records.
- Logout only deletes DB rows.

Why it causes the reported symptoms:

- A host can believe a party is gone while old guest URLs remain usable until restart.
- That is both a security leak and another explanation for “weirdly stale” behavior after logout.

## Minor Frontend / Miscellaneous Bugs

### 27. Several asset whitelist entries do not match real files

Files:

- `server.rb:111-129`
- `views/assets/`

What is wrong:

- The whitelist includes paths like `/assets/favicon-16x16.ico`, `/assets/favicon-32x32.ico`, `/assets/android-chrome-512x512`, and `/assets/android-chrome-192x192`.
- The actual files are `.png`.

Why it causes the reported symptoms:

- Some icons will 404 if requested.
- This is minor, but it confirms the asset path handling is brittle.

### 28. The queue page has malformed HTML

Files:

- `views/queue_song.erb:37`

What is wrong:

- The “Felix Krause” link is missing its closing `</a>`.

Why it causes the reported symptoms:

- Browsers usually recover, but malformed DOM can cause layout/debugging oddities and is another sign the page was not validated carefully.

## Most Likely Root Causes Of “Songs Don’t Play”

The strongest explanations for the reported production symptoms are:

1. In-memory-only queue state being lost across restarts or between processes.
2. Races around `queued_songs` / `currently_playing_guest_wished_song`.
3. Returning success before the Sonos insert succeeds.
4. Failed first inserts wedging the queue because the state says a guest song is active when none was actually queued.
5. Sonos callback events being delayed/dropped because the handler does too much before returning `200`.
6. Sonos subscriptions expiring or never being recreated after a group change.

If I had to prioritize fixes, I would start there before touching any cosmetic frontend issues.
