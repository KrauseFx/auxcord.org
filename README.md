# Jukebox for Sonos

Do you have a Sonos system, and are hosting a party? Let's gooo

## Problem

- You are hosting a party at your place, and want to play music in the background, you start with a some pre-made `Party with friends` playlist
- Guests request songs, which gives you a few options
  1. Take your phone, launch the Sonos app, and search for that specific song, mispell it maybe, then press the little dots, to then queue the song
  2. Unluck and hand them your phone, only for guests to be overwhelmed with the (not so great) Sonos app, and then just overwriting the queue and what's playing, with their song
  3. Tell them `No`
- Guests might change the volume of your Sonos speakers using the hardware buttons, especially on the Sonos Move or Roam, or might even pause the music. You as the host probably want to be in control of the volume to consider the neighbours.

## Requirements

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
