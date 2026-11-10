# Slate roadmap

## Done
- [x] Organization approved: `dev.alloycore`
- [x] Got `RomGen.py` (github.com/emexlab/Nyxian)
- [x] Inspected a Switzach ROM, notes in `docs/format.md`

## Phase 1: Keys
- [x] Release key registered (ROM id `dev.alloycore.slate`, install tickets on)
- [ ] Dev key: `python3 RomGen.py genkey --name slatedev` (needs Python 3 + openssl; a Codespace works)
- [ ] Back up `slatedev.key.pem` somewhere private (never commit it)
- [ ] Register `slatedev.pub.pem` as "SLATE DEV ROM KEY" for `dev.alloycore.slatedev`, install tickets off
- [ ] `python3 RomGen.py prove --key slatedev.key.pem 'CODE'` and paste the result
- [ ] Wait for emexLabs to approve the key and publish the TrustStore

## Phase 2: First build
- [ ] Add the dev private key as the repo secret `ROM_SIGNING_KEY` (private repo only)
- [ ] Run the "Build Slate Dev ROM" workflow (macOS runner, builds the stock template)
- [ ] Download `rom.zip` from the run's artifacts, flash it in Nyxian

## Phase 3: Make it Slate
- [ ] Commit the generated template into this repo and build from it
- [ ] Settings screen with About and developer menu (`docs/settings-edits.md`)
- [ ] Custom boot screen with the Slate logo (`rom/src/NXBootGraphics.m`)
- [ ] First-run setup flow after each flash
- [ ] Replace the Hello app with Slate's own app (`appsrc/`)
- [ ] Bump `NXRomSecurityVersion` for every release

## Phase 4: Ship
- [ ] Add the release private key as the repo secret `ROM_RELEASE_KEY`
- [ ] Run the workflow with the "release" option
- [ ] List the build's digest under Signed releases on the portal (install tickets)
- [ ] `python3 RomGen.py verify rom.zip --truststore online`
- [ ] Publish a release
