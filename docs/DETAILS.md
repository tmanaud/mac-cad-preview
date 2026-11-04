# Mac CAD Preview details

[Back to the landing page](../README.md).

## Controls

### 3D models

| Action | Control |
| --- | --- |
| Orbit | Drag |
| Zoom | Scroll; towards the pointer by default |
| Pan | Two-finger drag or right-button drag |
| Show sharp and boundary edges | **Edges** |
| Use orthographic projection | **Ortho** |
| Show the file's colours or a neutral finish | **Model colours**, shown only for multi-colour models |
| Copy bounding box dimensions | Click the dimensions |
| Change defaults | **Settings** |
| Open a STEP or IGES file in Autodesk Fusion | **Fusion**, shown when Fusion is installed |

The initial view frames the tessellated part with a small margin. Dimensions
and framing use the actual triangles, not the untrimmed NURBS surface bounds.
The bottom left also shows the face and triangle counts.

Zoom follows the point under the pointer. Rotation then re-anchors there,
so you can inspect a feature up close. Models start with Z pointing up.
The zoom target, direction, up axis and starting view can all be changed.

### Text and archives

G-code is highlighted text, not a 3D toolpath. G and M words, axis addresses,
feed and speed, tools and comments have distinct colours.

Markdown opens as a rendered document. **Rendered / Source** switches to the
original text and saves that choice for later previews.

Zip, RAR and 7z previews list folders, names and uncompressed sizes without
extracting members. A 3MF file remains a 3D preview even though it contains zip data.

**A− / A+** change text size. G-code, Markdown and archive listings each save
their own size. **Settings** opens the host app's settings window, also available
from **Settings…** (⌘,) in the app.

## Settings

| Setting | Choices and default |
| --- | --- |
| Model colours | On by default |
| Edges | On by default |
| Projection | Perspective by default; orthographic available |
| Zoom direction | Scroll up zooms in by default; can be inverted |
| Zoom target | Pointer by default; window centre available |
| Up axis | Z up by default; Y up available |
| Initial view | Isometric by default; front or top available |
| G-code lines | Wrap by default; horizontal scrolling available |
| G-code colours | Colourful by default; muted or plain available |
| Markdown view | Rendered by default; source available |
| Text sizes | 12 pt by default, from 9 to 24 pt; separate for each preview type |

[PreviewPreferences.swift, the shared settings store](../src/shared/PreviewPreferences.swift),
saves a plist in the extension's sandbox container, under
`Data/Library/Application Support/MacCADPreview/preferences.plist`.
The unsandboxed host app writes the same file. The preview's **Settings** link
asks the XPC helper to open the app's settings URL. This does not use an App Group.

## Updating and removing the app

Download a new DMG from [this fork's releases](https://github.com/tmanaud/mac-cad-preview/releases),
replace the app in Applications and open it once. A fresh download needs approval
under System Settings → Privacy & Security → **Open Anyway** again.
The app window shows the installed version; [the changelog](../CHANGELOG.md)
records release changes.

[The uninstall commands](../README.md#uninstall) remove the app and the extension's
container, including settings and cached meshes. macOS removes the extension
registration when the containing app goes away.

## Troubleshooting

Start with [doctor.sh, the read-only diagnostic](../doctor.sh). From a checkout:

```bash
./doctor.sh yourpart.step
```

It checks the installation, quarantine, sandbox, extension registration and the
file type macOS assigned. It prints problems and suggested commands without
changing the installation. You can also download the diagnostic script from
this repository and run it locally.

### Nothing happens, or the preview is blank

1. **The app is quarantined or has not been opened.** Open it from Applications,
   then approve it in System Settings → Privacy & Security → **Open Anyway**.
   Opening it once also registers the extension. A locally built copy is never
   quarantined.
2. **The extension is switched off.** In System Settings → General → Login Items
   & Extensions → Quick Look, enable Mac CAD Preview. The settings location can
   vary with macOS version.
3. **Another app has claimed the file type.** Quick Look uses the type macOS
   assigned, not just the filename. The diagnostic above reports the type and
   the app. If that type is not handled, include the relevant line in
   [an issue for this fork](https://github.com/tmanaud/mac-cad-preview/issues).

Check whether macOS can see the extension:

```bash
pluginkit -m -i com.maccadpreview.quicklook
```

A leading `+` means registered and enabled. A blank first column can still mean
registered. No output means it is not registered; check quarantine and open the
app once. To clear quarantine directly:

```bash
xattr -dr com.apple.quarantine "/Applications/Mac CAD Preview.app"
open "/Applications/Mac CAD Preview.app"
```

If you moved the app, refresh the registration at its installed location:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Mac CAD Preview.app"
```

### One file will not open

Some exporters put gzip compressed data in a file with a STEP extension.
Check the file with:

```bash
file yourpart.step
```

If it reports `gzip compressed data`, that is not yet supported.
For other problems, inspect the extension's system log:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.maccadpreview"'
```

## Known limitations

- Apple Silicon only, on macOS 12 or later. Intel Macs are not supported.
- No Finder icon thumbnails: previews appear when you press Space.
- No gzip compressed STEP, OBJ or PLY support.
- STL and basic 3MF previews do not show model colours.
- G-code is text, not a toolpath simulation.
- G-code and Markdown previews show only the first 1 MiB of large files.
- Archive previews are listings only. Encrypted headers cannot be listed
  without a password; listings stop at 10,000 entries and note truncation.

## Formats and tessellation

[The format table](../README.md#formats) lists the supported extensions.
STEP and IGES describe boundary representation geometry, including trimmed
NURBS surfaces. [OpenCASCADE](https://dev.opencascade.org) tessellates those
surfaces into triangles for display.

STEP colours can be attached to a whole solid or an individual face through
`styled_item` entities. STEP and IGES colours are read where the exporter wrote
them; missing colour data falls back to neutral grey. Triangles are grouped by
colour, with one draw call per group. STL and 3MF provide mesh geometry directly;
3MF support is limited to the basic mesh.

## Performance and cache

The first preview of a large model can take seconds. The panel reports whether
it is parsing, tessellating or reading a mesh, and warns about large files.
STEP text parsing can dominate the time, so lower tessellation quality would
not remove that cost.

Earlier measurements recorded about 19 seconds for a 56 MB assembly, and
3.15 seconds for an 8.2 MB model with 96,808 triangles. The latter's cached
preview was reported as 0.00 seconds. These are examples from the original
README, not benchmarks for every machine or file.

[MeshData.swift, the mesh cache implementation](../src/qlext/MeshData.swift),
keys entries on file path, size and modification time. Re-exporting a part
invalidates its previous entry. Later previews are instant while the result
remains cached. The cache is capped at 512 MiB and evicts least recently used
entries first.

The cache lives in the Quick Look extension's sandbox container. Clear it with:

```bash
rm -rf ~/Library/Containers/com.maccadpreview.quicklook/Data/Library/Caches/MacCADPreview
```

## Building, packaging and signing

[The build instructions](../README.md#build) need Command Line Tools and
[Homebrew](https://brew.sh); the full Xcode app is not required. Install the
Command Line Tools if needed with:

```bash
xcode-select --install
```

[build.sh, the build script](../build.sh), produces the app in the build directory.
Copy it to Applications and open it once to register the extension. To inspect
the installed app's version:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "/Applications/Mac CAD Preview.app/Contents/Info.plist"
```

[The test fixture guide](../tests/README.md) describes the sample files.
[RELEASING.md, the release guide](../RELEASING.md), describes versioning and
the release workflow.

[install.sh, the convenience installer](../install.sh), checks requirements,
installs dependencies, then builds and installs this fork's newest release.
Its `--ref main` option selects development code; `--yes` skips
dependency-installation prompts. The manual build steps above use your current
checkout instead.

[package.sh, the packaging script](../package.sh), builds the app and creates a
versioned DMG in the build directory, with an Applications link and installation
instructions. It prints a SHA-256 checksum for the release notes.

The app bundles its OpenCASCADE dependencies and rewrites their library paths.
A downloaded build needs neither Homebrew nor Command Line Tools. Library count
and compressed size depend on the dependency versions used for the build.

The app, extension and helper are ad-hoc signed, with no Apple Developer ID.
The download is not notarised. Gatekeeper approval is needed before the downloaded
extension can load; a locally built copy is never quarantined.

The extension is signed with its own entitlements, including
`com.apple.security.app-sandbox`. PlugInKit requires the extension to be sandboxed.
Signing is done from the libraries outwards, not with `codesign --deep`, which
would flatten entitlements. Deep verification is used after signing.

[scripts/screenshots.sh, the demo renderer](../scripts/screenshots.sh), generates
the demo files and renders the landing-page pictures. It needs macOS, OpenCASCADE
and ffmpeg. It produces light and dark animations and reduced-motion stills.

## How it works

The build script assembles the host app and embedded Quick Look extension without
an Xcode project. The host app provides the version window and settings. The
extension's entry point is `NSExtensionMain`; an embedded XPC helper opens settings
and hands supported files to Fusion.

The geometry core is C++ over OpenCASCADE, exposed to Swift through
[cadmesh.h, the geometry C API](../src/core/cadmesh.h). It reads and tessellates the
file, groups triangles by colour and returns flat buffers for SceneKit geometry.
Quick Look extensions are sandboxed, so the build walks the library dependency
graph and bundles the required libraries instead of loading them from Homebrew.

Quick Look can terminate extensions that take too long to respond. The panel
therefore reports itself ready immediately, then loads geometry on a background
queue and displays it when ready.

G-code skips the geometry core and uses a scrollable text panel with syntax
colouring. Markdown uses Foundation's CommonMark parser and attributed text;
source view shows the original text. Both truncate large text previews to avoid
stalling layout.

Archive listings read headers with the system libarchive and do not unpack
members. Entry and nesting limits keep very large listings bounded.

## Third-party licences

The project is MIT licensed: see [LICENSE, the licence text](../LICENSE).
The built app links against and bundles these unmodified libraries:

| Library | Licence |
| --- | --- |
| OpenCASCADE Technology | LGPL-2.1 with the Open CASCADE exception |
| FreeType | FreeType Licence (BSD style) |
| libpng | PNG Reference Library Licence |
| Intel oneTBB | Apache 2.0 |
| Brotli (a FreeType dependency) | MIT |

These libraries arrive through Homebrew at build time and are copied into the
app bundle; their source is not vendored in this repository. Redistributing a
built app carries the notice requirements of those licences.
