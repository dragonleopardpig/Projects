# Enhanced Dirvish

A full graphical file manager for Emacs, built on
[Dirvish](https://github.com/alexluigit/dirvish).

- **Four views:** Columns (Miller), Icons (thumbnail grid), List (tree) and
  Compact, switched with `C-1` … `C-4`
- **Places sidebar** with Home, Computer, Trash, Network, Recent, pinned
  folders (shared with GTK bookmarks) and devices (mount, unmount, unlock)
- **Tabs** that are restored next session, and a Nemo-style **split pane**
  (`F3`) with copy/move across panes
- **Rich previews** of images, PDFs, video, audio, archives, fonts and
  documents; text previews can be **edited in place**
- **Search and filters**, trash with **undo/redo**, archives (compress,
  encrypt, extract), custom actions, per-folder colours and icons
- **Live refresh** through file notifications, with guards for FUSE,
  network and removable mounts
- Mouse support throughout: selection, drag and drop, context menus
- Two key schemes: desktop-style keys (default) and a modal "10xer" mode with
  Vi/Yazi-like keys and chords (`C-S-m` switches)

## Requirements

- Emacs 29.1 or later
- [Dirvish](https://github.com/alexluigit/dirvish) 2.0 or later (MELPA or
  NonGNU ELPA)

Optional external tools, each enabling one feature (Settings & Diagnostics,
`C-,`, shows which are found):

| Tool | Used for |
|---|---|
| `fd`, `rg` | Search, content search |
| `gio` | Trash and GVfs mounts |
| `udisksctl` | Mount, unmount, LUKS unlock |
| `vipsthumbnail`, `ffmpegthumbnailer` | Image and video thumbnails |
| `mpv`, `mediainfo` | Audio/video preview and badges |
| `pdftoppm` | PDF previews |
| `7z` | Archive preview, compress, extract |
| `pandoc` | Rendered Markdown and DOCX / ODT / RTF previews |
| Node.js and MathJax | Offline vector equations in Markdown previews |
| `exiftool` | Camera RAW / EXIF metadata |
| `fc-query` | Font previews |
| `wl-paste` | Pasting clipboard images and text as files (Wayland) |

Optional Emacs packages: `vterm` (the pane terminal falls back to
`ansi-term`), `dashboard` (adds navigator buttons) and `transpose-frame`.

Set `enhanced-dirvish-markdown-mathjax-directory` to the directory containing
`tex-svg.js` and the MathJax components if the bundle is installed outside
`$XDG_DATA_HOME/enhanced-dirvish/mathjax` (or `~/.local/share/enhanced-dirvish/mathjax`
when `XDG_DATA_HOME` is unset).

## Installation

From this repository, with Emacs 30:

```elisp
(use-package enhanced-dirvish
  :vc (:url "https://github.com/dragonleopardpig/enhanced-dirvish")
  :after dirvish
  :config (enhanced-dirvish-setup))
```

With Emacs 29, run `M-x package-vc-install` and give it the URL above, then
add `(enhanced-dirvish-setup)` to your init file.

Loading the package changes nothing; `enhanced-dirvish-setup` installs its
hooks and Dirvish settings. Then run `M-x enhanced-dirvish-launch`, or bind
it to a key of your own, for example `(keymap-global-set "C-c d"
#'enhanced-dirvish-launch)`.

## Keys

`?` (or `C-c ?`) opens the full, searchable shortcut reference. A few to
start with:

| Key | Action |
|---|---|
| `C-1` … `C-4` | Columns / Icons / List / Compact view |
| `F3` | Open or close the split pane |
| `C-t`, `C-w`, `C-S-t` | New tab, close tab, reopen closed tab |
| `C-b` | Toggle the Places sidebar |
| `` C-` `` | Toggle the pane terminal |
| `C-k`, `C-f` | Search, filter the folder |
| `F2`, `<delete>`, `C-z` | Rename, move to Trash, undo |
| `S-F10` / right click | Context menu |
| `M-v` (Alt+V) | Switch HTML, Markdown and SVG previews between rendered and source |
| `C-,` | Settings & Diagnostics |
| `g` | Refresh (default key scheme) |

Emacs reserves F5–F9 and `C-c` followed by a letter for users, so these are
off by default. For Explorer/Nemo-style keys (`F5` refresh, `F6` switch pane,
`F9` terminal, `C-c s` sort, `C-c t` terminal, `C-c c`/`x`/`v` copy, cut,
paste), set this before `enhanced-dirvish-setup`:

```elisp
(setq enhanced-dirvish-file-manager-keys t)
```

## Configuration

Preferences can be changed in Settings & Diagnostics (`C-,`) and are kept in
`~/.emacs.d/dirvish/enhanced-dirvish/`. Defaults, folder colours and custom
actions can also be set in `$XDG_CONFIG_HOME/enhanced-dirvish/settings.toml`
and `$XDG_CONFIG_HOME/enhanced-dirvish/actions/`.

## Development

```sh
emacs -Q --batch --eval "(progn (require 'package) (package-initialize))" \
      -l enhanced-dirvish-tests.el -f ert-run-tests-batch-and-exit
```

The tests load `enhanced-dirvish-window-tests.el` themselves. CI also
byte-compiles every file with warnings as errors and runs `package-lint`.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
