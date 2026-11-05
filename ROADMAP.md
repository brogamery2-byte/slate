# Slate roadmap

## Phase 0: Access
- [ ] Request an organization at developer.emexlabs.org (reverse-DNS id)
- [ ] Get `RomGen.py` and generate a keypair (`genkey`)
- [ ] Store the private key somewhere safe, outside this repo

## Phase 1: Learn the format
- [x] Inspect an existing ROM zip (structure, manifest, metadata)
- [ ] Read the emexOS and Nyxian docs for ROM requirements
- [x] Write findings into `docs/format.md`

## Phase 2: Minimal ROM
- [x] Write a `manifest.plist` for Slate (own identifier, version 1, security 1)
- [ ] Tiny `System/Rom/init` and `uninstall`
- [ ] Smallest ROM that flashes and boots
- [ ] Custom boot screen

## Phase 3: System
- [ ] Home UI
- [ ] First built-in app

## Phase 4: Ship
- [ ] Sign with `RomGen.py sign`
- [ ] Wait for TrustStore approval
- [ ] Publish a release
