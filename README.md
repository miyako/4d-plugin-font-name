# 4d-plugin-font-name

The `font-name` plugin converts between a macOS font's internal (PostScript) name and its user-facing display name, using Cocoa's `NSFont`/`NSFontManager` APIs. It exposes a single command, `FONT Convert name`, and returns a `Text` value in both directions.

## Summary

| Command | Returns | Purpose |
|---|---|---|
| [`FONT Convert name`](#font-convert-name) | Text | Convert a font name between its internal (PostScript) name and its display name, in either direction. |

**Platforms:** macOS. The supplied source implements this command entirely with Cocoa/AppKit APIs (`NSFont`, `NSFontManager`) and contains no `#if VERSIONWIN` branch or other Windows code path — if a Windows build of this plugin exists elsewhere, it isn't covered by this doc.

## Versioning and publication

Run **Bump version** manually, explicitly selecting the destination branch and
`patch`, `minor`, or `major`. It validates the dispatched immutable commit, clean
checkout, remote branch and coordinated source metadata before committing only
`font-name.xcodeproj/project.pbxproj`, `Info.plist`, and
`English.lproj/InfoPlist.strings`. It creates no tag and triggers no Build.
The branch must still point to the selected SHA at both remote checks and in
the push server's advertisement. A required executable pre-push guard rejects
advances, rewinds, deletions and same-result races after the final check.
Only that explicit branch is pushed, nonforce, with both `push.followTags=false`
and `--no-follow-tags`; a missing guard fails closed.

Run **Build** separately on the desired branch. It has no custom inputs and every
checkout uses the dispatched `github.sha`, not a moving branch or tag.
`MARKETING_VERSION` is the authoritative strict `X.Y.Z`; all six
`CURRENT_PROJECT_VERSION` settings, literal source plist version fields, and
localized source display versions must agree. Known Xcode version-variable
references are preserved and resolved through that authority. An absent optional
`CFBundleVersion` stays absent. Prebuilt bundles, API/dependency versions and 4D
format/schema metadata are not version inputs.

The old bump workflow promised coordinated marketing/current-project versions
but only changed marketing versions. This migration repairs the six stale
`CURRENT_PROJECT_VERSION = 1.0.0` settings and localized `1.0` display overrides
to the existing authoritative **1.0.3**, without incrementing the source version
or changing the copyright year.

Build retains the existing macOS universal build, Developer ID signing and
signature verification, ZIP/DMG notarization, and DMG stapling gates. Despite the
old workflow's Windows comments and unused solution variable, it had no Windows
job; this AppKit-based plugin's pipeline remains macOS-only. Asset names remain
`font-name-X.Y.Z.zip` and `font-name-X.Y.Z.dmg`, with unchanged secret names.

Build runs serialize repository-wide across branches. Before native work and
again immediately after all build/sign/notary/staple gates, authenticated
paginated release listings (including drafts) and remote tags must show no
`vX.Y.Z`. Every page and entry is validated; HTTP 404, authorization/network
errors, malformed responses, and failures on later pages stop publication.
Only a complete successful no-match listing means absent.

Publication creates a new lightweight tag at the exact selected SHA using REST
`POST git/refs`, verifies its remote SHA, then uses create-only REST
`POST releases` with explicit tag, commit, name, `draft=false`,
`prerelease=false`, and the original empty/no-generated-notes policy.
Assets are POSTed only to the newly returned release ID. Concurrent tag
creation is an error even at the same SHA. There is no update, clobber,
deletion, rollback, automatic retry, or `gh release create` temporary draft.

**Manual recovery:** any failure stops the run and retains an already-created
tag, release, or uploaded assets. Inspect the error, remote tag SHA, draft and
published releases, and accepted assets before taking an explicit human recovery
action. Do not blindly rerun: retained state deliberately blocks publication.
A failed bump may leave a local metadata commit but never force-updates a moved
branch; review the destination and dispatch again from its current commit.

Local lifecycle checks (no native build, signing or remote publication):
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/tests -q`.

---

## Requirements & platform notes

- Both parameters of `FONT Convert name` are mandatory — there is no optional/shorter form.
- The command reads the **live list of fonts installed on the machine running the command**. The same input can return different results (or an empty string) on a different machine, depending on what's installed there.
- **Failure is silent, not a 4D error.** If no matching font can be resolved, the command returns an empty `Text` — it does not raise an error you can trap. See [Error handling](#error-handling--troubleshooting).
- No special permissions or minimum macOS version are implied by the APIs used (`NSFont`, `NSFontManager` are long-standing AppKit classes); none is asserted here beyond that.

---

## FONT Convert name

### Syntax

```
FONT Convert name ( name ; direction ) → Text
```

| Parameter | Type | Description |
|---|---|---|
| `name` | Text | The font name to convert. Pass a font's internal (PostScript) name when converting *to* a display name, or a display name when converting *from* one. |
| `direction` | Longint | Conversion direction. Pass the `To display name` constant to convert an internal font name into its display name, or `From display name` to convert a display name back into the internal name. Any value other than `To display name` is treated as `From display name` — the plugin does not validate `direction` against a fixed enum. |
| Result | Text | The converted name, or an empty string if no matching font could be resolved. |

### Description

`To display name` looks up the font by its internal (PostScript) name and, if found, returns the name macOS shows the user in font menus and pickers (`NSFont`'s `displayName`). If no installed font has that internal name, the command returns an empty string.

`From display name` does the reverse, in two steps:
1. It first tries the input directly as if it were already an internal font name (some fonts' internal and display names are identical, so this can succeed immediately).
2. If that fails, it falls back to scanning every font currently installed on the machine, comparing each one's display name against the input for an exact match. This fallback is why the first `From display name` call in a session can be noticeably slower than a direct hit — it's building and checking a font object for every installed font family until it finds a match (or exhausts the list).

Name comparison in both directions is an exact string match — there's no case-insensitive or locale-aware fallback.

### Example

From the plugin's own test method (`Method1.4dm`):

```4d
$name1a:=FONT Convert name("AquaKana"; To display name)
//.Aqua Ç©Ç»

$name1b:=FONT Convert name($name1a; From display name)
//AquaKana

$name1a:=FONT Convert name(".SFNSDisplay-Regular"; To display name)
//ÉVÉXÉeÉÄÉtÉHÉìÉg ÉåÉMÉÖÉâÅ[

$name1b:=FONT Convert name($name1a; From display name)
//.SFNSDisplay-Regular

$name1a:=FONT Convert name("Meiryo Bold Italic"; To display name)
//ÉÅÉCÉäÉI É{Å[ÉãÉh ÉCÉ^ÉäÉbÉN

$name1b:=FONT Convert name($name1a; From display name)
//Meiryo-BoldItalic
```

Converting a whole list of internal font names to display names at once:

```4d
ARRAY TEXT($internalNames; 0)
ARRAY TEXT($displayNames; 0)

APPEND TO ARRAY($internalNames; "Helvetica-Bold")
APPEND TO ARRAY($internalNames; "Meiryo Bold Italic")
APPEND TO ARRAY($internalNames; "AquaKana")

For ($i; 1; Size of array($internalNames))
  APPEND TO ARRAY($displayNames; FONT Convert name($internalNames{$i}; To display name))
End for
```

Round-tripping and checking for the silent-failure case:

```4d
$display:=FONT Convert name($fontName; To display name)

If ($display="")
   // no installed font matched $fontName
ELSE
  $backToInternal:=FONT Convert name($display; From display name)
End if
```

---

## Error handling & troubleshooting

- **An empty string means "no match," not a 4D error.** Neither direction raises a trappable error on failure — always check whether the result is `""` if the input name might not correspond to an installed font.
- **Results depend on the fonts installed on the machine that runs the command.** A conversion that succeeds in development can return `""` on a machine (or server) with a different font set installed.
- **The first `From display name` fallback lookup in a session can be slower than later ones**, since it has to check every installed font's display name before concluding there's no match; a direct-name hit (step 1 above) is fast regardless of how many fonts are installed.
- **`direction` isn't validated as a strict enum.** Passing anything other than the `To display name` constant is treated as `From display name` — there's no third state or error for an unrecognized value.
- **Name matching is exact and case-sensitive** in both directions — no fuzzy or case-insensitive matching is performed.

---

## Quick reference

```4d
 // internal name -> display name
$display:=FONT Convert name("Helvetica-Bold"; To display name)

 // display name -> internal name
$internal:=FONT Convert name($display; From display name)

 // always check for the silent-failure case
If ($internal="")
   // no installed font matched
End if
```
