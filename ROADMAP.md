# Slate roadmap

## Done
- [x] Organization approved: `dev.alloycore`
- [x] Got `RomGen.py` (github.com/emexlab/Nyxian)
- [x] Inspected a Switzach ROM, notes in `docs/format.md`

## Phase 1: Keys
- [ ] `python3 RomGen.py genkey --name slate` (needs Python 3 + openssl; a Codespace works)
- [ ] Back up `slate.key.pem` somewhere private (never commit it)
- [ ] Register `slate.pub.pem` on the Developer Portal Keys page
- [ ] `python3 RomGen.py prove --key slate.key.pem 'CODE'` and paste the result
- [ ] Wait for emexLabs to approve the key and publish the TrustStore

## Phase 2: First build
- [ ] Add the private key as the repo secret `ROM_SIGNING_KEY` (private repo only)
- [ ] Run the "Build Slate ROM" workflow (macOS runner, builds the stock template)
- [ ] Download `rom.zip` from the run's artifacts, flash it in Nyxian

## Phase 3: Make it Slate
- [ ] Commit the generated template into this repo and build from it
- [ ] Custom boot screen (`rom/src/NXBootGraphics.m`)
- [ ] Replace the Hello app with Slate's own app (`appsrc/`)
- [ ] Bump `NXRomSecurityVersion` for every release

## Phase 4: Ship
- [ ] `python3 RomGen.py verify rom.zip --truststore online`
- [ ] Publish a release
