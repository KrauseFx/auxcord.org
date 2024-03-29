# [auxcord.org](auxcord.org)

Do you have a Sonos system, and are hosting a party? Let's gooo

## Problem

- You are hosting a party at your place, and want to play music in the background, you start with a some pre-made `Party with friends` playlist
- Guests request songs, which gives you a few options
  1. Take your phone, launch the Sonos app, and search for that specific song, mispell it maybe, then press the little dots, to then queue the song
  2. Unluck and hand them your phone, only for guests to be overwhelmed with the (not so great) Sonos app, and then just overwriting the queue and what's playing, with their song
  3. Tell them `No`
- Guests might change the volume of your Sonos speakers using the hardware buttons, especially on the Sonos Move or Roam, or might even pause the music. You as the host probably want to be in control of the volume to consider the neighbours.

## Project Goals

- Easy setup for the host, not requiring any engineering skills
- No hardware that needs to run at the host's home, besides the Sonos system itself
- Guests being able to queue new songs, without having to have a Spotify subscription, and no matter if they have an iPhone or Android

## Solutions

A simple web-app, that does the following

1. The host lands on the page, and connects their Sonos and their Spotify accounts
2. Only the first time, they need to add a Spotify playlist (created by this web app) to their Sonos favorites, so it can be used. An assistant helps you go through this
3. The host gets a URL and QR code, that they can share with their guests (printed out at the party)
4. The host gets to choose a few attributes for that specific party (e.g. volume per speaker)
5. A guest accessing the URL lands on a plain, single-page website that has a single text field to search for a specific song

There are many additional features we could build (like pre-queuing songs before a party), but for now, we want to get the basics right first

# Self-hosted deployment
## Docker 
1. Copy the file `docker-compose.yml` to the directory you will use for your deployment
2. Copy the file `.env.example` to the same directory and rename it to `.env`
3. Fill the values in the `.env` file
4. Run `docker-compose up -d`
5. The project web UI will be available at 0.0.0.0:4597. You can then use a reverse proxy like Traefik to use HTTPS and other configurations with your domain.

Note: Database files will be saved to the selected directory, under `./data` (see the `volumes` section of the `docker-compose.yml` file)

## Requirements to use this project

1. A Sonos sound system
1. A Spotify account

## Development

### Dependencies

```
bundle install
```

Developed with Ruby 3.0.2

### Running the server

```
bundle exec ruby server.rb
```
### Cloudflare tunnel to test Sonos Web hooks

```
cloudflared tunnel run satisfactory-opt-some-chen-fx
```

This will build up the tunnel to expose

```
https://runnel.felixkrause.me/
```

for the SONOS webhooks

### Hosting

This is hosted on https://railway.com/ at the time of writing

### Meme

- https://knowyourmeme.com/memes/hand-me-the-aux-cord
- https://knowyourmeme.com/memes/when-you-give-x-the-aux-cord
