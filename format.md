# ROM format notes

Observed from inspecting a Switzach ROM zip (`org.emexlabs.switzach`,
v1.0.5). Anything not listed here is unknown. Verify against the official
emexLabs docs before relying on it.

## Zip layout

A single top-level `ROM/` folder:

```
ROM/
  manifest.plist            ROM metadata + per-file rules
  System/
    Rom/init                ROM entry point (NXRomExecutable)
    Rom/uninstall           removal script (NXRomUninstaller)
    Library/
      CoreServices/SpringBoard.app/   the ROM's home screen
      LaunchDaemons/*.plist           services started at boot
      Wallpaper/
  usr/libexec/              daemons (e.g. bootstrapd)
  binpack/                  command line tools (bin, sbin, usr/bin, ...)
  Application/<Name>.app/   the ROM's own app(s)
  bootstrap.tar.zst         extra payload
```

## manifest.plist keys

| Key | Meaning (as observed) |
| --- | --- |
| `NXRomManifestVersion` | Manifest format version (1) |
| `NXRomIdentifier` | Reverse-DNS id, e.g. `org.emexlabs.switzach` |
| `NXRomName` | Display name |
| `NXRomVersion` | Release version, e.g. `1.0.5` |
| `NXRomSecurityVersion` | Integer that only goes up (anti-rollback) |
| `NXRomMinimumNyxianVersion` | Oldest Nyxian that can flash it |
| `NXRomDefaultFilePermission` | Default file mode (420 = 0644) |
| `NXRomDefaultDirectoryPermission` | Default directory mode (493 = 0755) |
| `NXRomExecutable` | Entry point path (`System/Rom/init`) |
| `NXRomUninstaller` | Uninstall path (`System/Rom/uninstall`) |
| `NXRomPaths` | List of per-file rule groups (below) |

### NXRomPaths entries

Each entry covers one or more paths:

- `NXPath`: a path or list of paths inside `ROM/`
- `NXPermission`: file mode (365 = 0555, executable)
- `NXRequiresCodeSigning`: true for binaries
- `NXT2Entitlements`: optional privileges for that binary, using
  `org.emexlabs.nyxian.*` keys (process spawn, task ports, sandbox file
  access, launch services, ...)

Example: SpringBoard gets a small entitlement set and an allow-list of
launch-service endpoints, while core tools get broad ones. Give each
binary only what it needs.

## Launch daemons

`System/Library/LaunchDaemons/*.plist` uses `PE*` keys:

```
PEServiceIdentifier   org.emexlabs.bootstrapd
PEExecutablePath      $(NXROOT)/usr/libexec/bootstrapd
PEEnabled / PEShouldAutorestart   true
```

`$(NXROOT)` is the ROM's root.

## Home screen

`SpringBoard.app/Info.plist` is a normal iOS app plist (hidden app tag,
scene delegate class, iOS 18+).

## Unknown

- Where the signature lives (none visible inside the zip)
- What `init` and `uninstall` actually do (compiled binaries)
- How the window server and boot screen are provided
- Whether the Nyxian SDK has headers for the `NX*` classes

## Licensing note

Switzach bundles third-party software (its zip includes licenses for
Dopamine, Zebra, Sileo, NewTerm and Irisin). Do not copy another ROM's
binaries into Slate. Write your own, or comply with each license if you
reuse something.
