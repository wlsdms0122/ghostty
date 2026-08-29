# .jsilver

Fork-only files. Nothing upstream reads this directory, so it never conflicts
when catching up with `upstream/main`.

## Build on a new machine

Needs [mise](https://mise.jdx.dev) (which supplies the pinned Zig) and Xcode.

```
git clone https://github.com/wlsdms0122/ghostty
cd ghostty
.jsilver/build.sh install
```

`install` builds a release app and replaces `/Applications/Ghostty.app`.
`build` leaves it in `macos/build/ReleaseLocal/` instead, and `--debug` on
either one builds the debug configuration into `macos/build/Debug/`.

An app built this way is signed ad-hoc, which is enough for the machine that
built it. `dist` is what makes a bundle another machine will open without
`xattr -dr com.apple.quarantine`:

```
.jsilver/build.sh dist <notarytool-keychain-profile>
```

That one needs the Developer ID certificate in the login keychain, so it only
runs on the owner's machine.

## Branches and versions

`main` ← `develop` ← `feature/XXX`, merged with `--no-ff`. Fork releases are
tagged `vX.Y.Z-jsilver.N`, matching `.version` in `build.zig.zon` — the tag
check in `src/build/Config.zig` compares them and panics on a mismatch, so a
release build is also the check that the two agree.

`upstream` is a remote, not a branch. Catching up is `git merge upstream/main`
on a `feature/upstream-sync` branch, built and tested before it reaches
`develop`.
