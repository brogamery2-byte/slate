# Slate

A custom ROM for [Nyxian](https://emexlabs.org/Nyxian/) by emexLabs.

> **Status:** early planning. Nothing here boots yet.

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

Folders get added as the ROM takes shape. See [ROADMAP.md](ROADMAP.md).

## Signing and security

ROMs must be signed with a key registered in emexLabs' TrustStore.

**Never commit your private key.** The `.gitignore` in this repo blocks
`*.key.pem` and similar files. Only the public key (`*.pub.pem`) is safe
to share.

## License

To be decided.
