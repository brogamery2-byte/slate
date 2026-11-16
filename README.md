# Slate

A custom ROM for [Nyxian](https://emexlabs.org/Nyxian/) by emexLabs.

[![Dev Build](https://github.com/brogamery2-byte/slate/actions/workflows/build-rom.yml/badge.svg)](https://github.com/brogamery2-byte/slate/actions/workflows/build-rom.yml)
[![Release Build](https://github.com/brogamery2-byte/slate/actions/workflows/release-rom.yml/badge.svg)](https://github.com/brogamery2-byte/slate/actions/workflows/release-rom.yml)
[![License: MIT](https://img.shields.io/github/license/brogamery2-byte/slate)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/brogamery2-byte/slate)](https://github.com/brogamery2-byte/slate/commits/main)

> **Status:** First Boot. Currently doesn’t have anything planned. (only has the settings menu)

## What is this?

Nyxian includes a bootloader that can flash and boot a ROM: a full system
with its own kernel surface, window server, apps and boot screen. Slate is
my attempt at building one.

## Goals

- Boot cleanly from Nyxian's bootloader
- Own boot screen
- Simple, clean home UI
- Signed and shipped through the emexLabs Developer Portal

## Project layout

Folders get added as the ROM takes shape. See [ROADMAP.md](ROADMAP.md) and [docs/format.md](docs/format.md).

## Testing

To download the developer version that isn’t in releases. Go to the [Actions build-rom.yml workflow](https://github.com/brogamery2-byte/slate/actions/workflows/build-rom.). And click the desired version. Then go to artifacts and download it.

**caution**: These versions aren’t made for stable usage

Then download the latest Nyxian .ipa file. You can find it in their discord or fluxer server. Then open it put your profile inside the app, then close the app and click on Advanced -> Flash ROM and select the rom.zip file

## Signing and security

ROMs must be signed with a key registered in emexLabs' TrustStore.

**Never commit your private key.** The `.gitignore` in this repo blocks
`*.key.pem` and similar files. Only the public key (`*.pub.pem`) is safe
to share.

## License

To be decided.
