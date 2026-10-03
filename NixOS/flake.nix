# Unified flake.nix for X299 and M90aPro
{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    grub2-themes.url = "github:vinceliuice/grub2-themes";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    djvu2pdf = {
      url = "github:dragonleopardpig/djvu2pdf";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # pdf-prep lives in its own repo now; this config consumed a ~575 line
    # embedded copy until 2026-08-30. Edit it there, not here.
    pdf-prep = {
      url = "github:dragonleopardpig/pdf-prep";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    minder-src = {
      url = "github:dragonleopardpig/Minder/latex-inline-shapes";
      flake = false;
    };
    formulaocr-offline = {
      url = "github:dragonleopardpig/formulaocr-offline";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    elephant.url = "github:abenz1267/elephant";
    walker = {
      url = "github:abenz1267/walker";
      inputs.elephant.follows = "elephant";
    };
  };

  outputs = inputs@{ nixpkgs, grub2-themes, home-manager, disko, ... }:
    let
      localOverlay = final: prev: {
        # Minder fork with local image-to-LaTeX recognition and inline Pango
        # formula shapes.  The non-flake input keeps the exact source revision
        # in flake.lock while allowing the fork to retain its upstream build.
        minder = prev.minder.overrideAttrs (old: {
          version = "2.0.9-inline-pango";
          src = inputs.minder-src;
          patches = [ ];
        });

        # Drop yt-dlp's deno (=> rusty-v8) dependency. The JS runtime is only
        # needed for full YouTube extractor support since 2025.11.12; without
        # it yt-dlp still works for everything we use it for, and we avoid
        # building rusty-v8 from source when cache.nixos.org doesn't have it.
        yt-dlp = prev.yt-dlp.override { javascriptSupport = false; };

        swappy = prev.swappy.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/swappy-multi-mime-clipboard.patch
            ./patches/swappy-save-as-dialog.patch
          ];
        });

        # Add a native two-page (book spread) mode to Sioyek. Upstream already
        # has the layout + toggle_two_page_mode command but ships it unbound and
        # with no way to start in it; the patch binds Ctrl+d, adds a
        # startup_two_page_mode config option, and keeps rectangle snapshots
        # aligned when both pages are visible. Source patch tracked in
        # ~/Projects/sioyek (fork of ahrm/sioyek) for upstreaming.
        sioyek = prev.sioyek.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/sioyek-dual-page.patch
            # Native DjVu, via a DjVuLibre-backed fz_document_handler. Generated
            # from ~/Projects/sioyek commit 3e471bd6. pkg-config is required or
            # the .pro's packagesExist(ddjvuapi) guard silently fails and you get
            # a Sioyek that builds fine and still cannot open a DjVu.
            ./patches/sioyek-native-djvu.patch
            # Everything from ~/Projects/sioyek's feature/reader-enhancements
            # branch, as one patch: persistent rectangle annotations, note boxes
            # that can be edited in place, moved and resized, per-note color and
            # border width, curved arrows that snap to the note's eight handles,
            # keyboard note colors from the a-z palette, a searchable list of
            # effective key bindings, exact-first command palette matching,
            # opening config files with a text editor, native LaTeX for inline
            # $...$ and display $$...$$ math, one unified note/rectangle object,
            # and the correctness fixes found auditing all of the above.
            #
            # This replaces the eleven separate note patches plus the audit-fix
            # patch. They were generated at different times from different branch
            # states and had drifted apart, so `patch` was applying some hunks
            # with fuzz — i.e. ignoring context and guessing the location.
            # Regenerate this file against the *materialised* tree (nixpkgs
            # source + dual-page + native-djvu, edited, then `diff -ruN`) and
            # always dry-run with `patch -p1 -F0` before committing. Note that
            # this nixpkgs snapshot is older than the branch's base, so branch
            # code touching newer upstream (e.g. db_mutex) does not transfer.
            ./patches/sioyek-reader-enhancements.patch
          ];
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ prev.pkg-config ];
          # final, not prev: the jkqtplotter below is patched in this same
          # overlay, and prev.* would silently pick up the unpatched one.
          buildInputs = (old.buildInputs or [ ]) ++ [ prev.djvulibre final.jkqtplotter ];
          qmakeFlags = (old.qmakeFlags or [ ]) ++ [
            "DEFINES+=SIOYEK_JKQT_MATHTEXT_SUPPORT"
          ];
        });

        # Four places where JKQTMathText's typesetting falls short of TeX's, all
        # of them visible when a formula is set beside the same one from a TeX
        # renderer. Sioyek's note LaTeX is the only consumer here.
        #
        # Rules: every rule -- fraction and matrix rules, radicals, decorations
        # like \vec and \overline, boxes, and the delimiters that \left..\right
        # build -- is drawn with a pen whose width is the font's underline
        # thickness. A text family such as Latin Modern Roman reports about
        # 2.8% of the font size there, under TeX's default rule thickness of
        # 0.04em, so the strokes come out light.
        #
        # Curly braces: the height of a \left\{ follows its contents, but its
        # width comes from a font metric and grows only with the square root of
        # the oversize factor, and the stem of the filled outline is simply the
        # text rule thickness. A brace around a two-line block therefore comes
        # out as a hairline a third of the width TeX gives it. TeX picks a wider
        # delimiter variant as the content grows and then extends that one, so
        # both now scale with the brace and saturate.
        #
        # Operator spacing: a math operator is padded by a factor of its own
        # glyph, which leaves a wide relation such as \leq or a multi-letter
        # name such as \cos with almost no room. TeX inserts a fixed skip that
        # does not depend on the glyph, 3mu next to an operator and 5mu next to
        # a relation.
        #
        # aligned/align: parsed as a plain matrix with an empty column spec, so
        # every column is left aligned and each \& gets the generic matrix
        # column separation. amsmath numbers the columns in pairs, right then
        # left -- that is what stacks the relation signs of successive lines --
        # and the \& inside a pair is an alignment point that adds no space.
        jkqtplotter = prev.jkqtplotter.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/jkqtplotter-tex-metrics.patch
          ];
        });

        # These four live in pythonPackagesExtensions rather than the top level
        # so the modules land in python3Packages: the scripts are invoked as
        # `python -m sioyek.<name>`, which needs them importable by a python
        # from python3.withPackages, not merely present in the profile.
        pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
          (pyfinal: pyprev: {
            # undetected-chromedriver downloads a chromedriver at runtime and
            # executes it. A binary fetched from the internet has no dynamic
            # loader on NixOS, so PyPaperBot's Google Scholar path would die the
            # moment it opened a browser. The patch makes it take the driver
            # named by NIX_CHROMEDRIVER instead -- set in the wrapper below to
            # the nixpkgs chromedriver, which matches the chromium installed
            # beside it. It is still copied somewhere writable first, because
            # the library byte-patches the binary to evade detection.
            undetected-chromedriver = pyprev.undetected-chromedriver.overridePythonAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                ./patches/undetected-chromedriver-use-system-driver.patch
              ];
              # The package installs no executable, so a wrapper could not
              # carry the variable: bake the path in as the default instead.
              postPatch = (old.postPatch or "") + ''
                substituteInPlace undetected_chromedriver/patcher.py \
                  --replace-fail "@NIX_CHROMEDRIVER@" "${final.chromedriver}/bin/chromedriver"
              '';
            });

          # Three small pure-Python packages that nixpkgs does not carry, needed
          # only so sioyek-python-extensions' paper_downloader.py can run.
          pychainedproxy = pyfinal.buildPythonPackage rec {
            pname = "pychainedproxy";
            version = "1.3";
            src = pyfinal.fetchPypi {
              inherit pname version;
              hash = "sha256-CA8BP21TXtd6nMmBLLvPAoYZXdSEuNHuKGY63rl4FI0=";
            };
            pyproject = true;
            build-system = [ pyfinal.setuptools ];
            propagatedBuildInputs = [ pyfinal.six ];
            doCheck = false;
            pythonImportsCheck = [ "pyChainedProxy" ];
            meta.description = "SOCKS proxy chaining for Python";
          };

          crossref-commons = pyfinal.buildPythonPackage rec {
            pname = "crossref_commons";
            version = "0.0.7";
            src = pyfinal.fetchPypi {
              inherit pname version;
              hash = "sha256-S4rjXUisxP5i2hZiUlOWR35PjHb9sAzULVM0xocTxLY=";
            };
            pyproject = true;
            build-system = [ pyfinal.setuptools ];
            # crossref_commons imports packaging at runtime but does not declare it.
            propagatedBuildInputs = with pyfinal; [ ratelimit requests packaging ];
            doCheck = false;
            pythonImportsCheck = [ "crossref_commons" ];
            meta.description = "Shared Crossref API utilities";
          };

          libgen-api = pyfinal.buildPythonPackage rec {
            pname = "libgen_api";
            version = "1.0.1";
            src = pyfinal.fetchPypi {
              inherit pname version;
              hash = "sha256-9WjbnDD11AvCiO1U46LeGJ0x3/DhqGA6CU0bHrasyeA=";
            };
            pyproject = true;
            build-system = [ pyfinal.setuptools ];
            propagatedBuildInputs = with pyfinal; [ beautifulsoup4 requests lxml ];
            # The declared dependency is the "bs4" stub distribution; the real
            # package is beautifulsoup4, which provides the same import.
            pythonRemoveDeps = [ "bs4" ];
            doCheck = false;
            pythonImportsCheck = [ "libgen_api" ];
            meta.description = "Search client for the Library Genesis catalogue";
          };

          # PyPaperBot declares its whole development environment as runtime
          # dependencies -- pylint, isort, mccabe, wrapt, astroid<=2.5 (2021),
          # idna<3, and HTMLParser, which is Python 2 only and does not install
          # here at all. Its actual imports are far fewer: bs4, crossref_commons,
          # bibtexparser, pandas, pyChainedProxy, selenium and
          # undetected_chromedriver. Supply those and drop the rest.
          #
          # It drives a real browser through undetected-chromedriver, so running
          # it needs a Chrome or Chromium on PATH as well.
          pypaperbot = pyfinal.buildPythonPackage rec {
            pname = "pypaperbot";
            version = "1.4.1";
            pyproject = true;
            build-system = [ pyfinal.setuptools ];
            src = pyfinal.fetchPypi {
              inherit pname version;
              hash = "sha256-O57AAoUETUZRAa2JehH2noJpdh8YnkyHyAwHGrMEluQ=";
            };
            propagatedBuildInputs = with pyfinal; [
              beautifulsoup4
              bibtexparser
              pandas
              numpy
              requests
              selenium
              undetected-chromedriver
              pyfinal.crossref-commons
              pyfinal.pychainedproxy
            ];
            pythonRemoveDeps = [
              "astroid" "HTMLParser" "idna" "isort" "mccabe" "pylint" "wrapt"
              "lazy-object-proxy" "future" "chardet" "toml" "six" "soupsieve"
              "certifi" "colorama" "pyparsing" "python-dateutil" "pytz" "urllib3"
            ];
            pythonRelaxDeps = true;
            doCheck = false;
            pythonImportsCheck = [ "PyPaperBot" ];
            meta.description = "Command-line tool for downloading scientific papers";
          };

          # ahrm/sioyek-python-extensions, published to PyPI as "sioyek". It drives
          # a *running* Sioyek over its local-socket command interface, so the
          # scripts are run against the instance you already have open.
          #
          # import_annotations is the one that earns its keep: it reads
          # annotations Sioyek did not create (Acrobat's, say) and writes them
          # into shared.db, matching each highlight's stroke colour to a Sioyek
          # highlight type and skipping any it already has. It only reads the
          # PDF, never rewrites it.
          #
          # libgen-api, pyChainedProxy and crossref-commons are packaged above so
          # paper_downloader.py works; it also needs a Chrome or Chromium on PATH,
          # since PyPaperBot drives one through undetected-chromedriver.
          #
          # translate.py is written against googletrans 3.1.0a0, an unmaintained
          # alpha. nixpkgs carries 4.0.2, whose Translator.translate is a
          # coroutine, so calling it the old way yields a coroutine and then
          # fails on .text. postPatch adapts the script instead of pinning a dead
          # release.
          sioyek-python-extensions = pyfinal.buildPythonPackage rec {
            pname = "sioyek";
            version = "0.31.11";
            pyproject = true;

            src = pyfinal.fetchPypi {
              inherit pname version;
              hash = "sha256-KzrwK21CU80rT2Stns3Iuly2+83w6MXPUdTLkqu9S+M=";
            };

            build-system = [ pyfinal.hatchling ];

            dependencies = with pyfinal; [
              pymupdf
              pypdf
              numpy
              pyqt5
              appdirs
              pyperclip
              habanero
              regex
              python-slugify
              googletrans
            ] ++ [
              pyfinal.libgen-api
              pyfinal.pypaperbot
            ];

            # PyPDF2 -- see postPatch. googletrans is supplied at 4.0.2 rather
            # than the pinned dead alpha.
            pythonRemoveDeps = [ "googletrans" "pypdf2" ];

            # PyPDF2 is end-of-life and nixpkgs marks 3.0.1 insecure over six
            # CVEs. Its maintained successor pypdf exposes the same four names
            # these two scripts import -- PdfWriter, PdfReader, PageObject,
            # Transformation -- so use that rather than whitelisting a package
            # with known vulnerabilities or dropping the scripts.
            postPatch = ''
              substituteInPlace src/sioyek/extract_highlights.py src/sioyek/dual_panelify.py \
                --replace-fail "from PyPDF2 import" "from pypdf import"

              # googletrans 4 made translate() a coroutine.
              substituteInPlace src/sioyek/translate.py \
                --replace-fail "import sys" "import asyncio, sys" \
                --replace-fail "translation = translator.translate(text, dest='en')" \
                               "translation = asyncio.run(translator.translate(text, dest='en'))"
            '';


            # Importing the package is the whole smoke test: it is a library plus
            # a set of __main__ scripts, and there is no test suite.
            pythonImportsCheck = [ "sioyek" "sioyek.sioyek" ];
            doCheck = false;

            meta = {
              description = "Python tools and extensions for the Sioyek PDF reader";
              homepage = "https://github.com/ahrm/sioyek-python-extensions";
              license = final.lib.licenses.gpl3Only;
            };
          };

          })
        ];

        # nixpkgs nwg-drawer (0.7.5) preInstall copies desktop-directories +
        # drawer.css to $out/share/nwg-drawer but forgets img/ — the upstream
        # Makefile copies all three. Without img/{lock,sleep,reboot,exit,
        # poweroff}.svg, the power-bar icons fall back to a "?" placeholder.
        # Drop once upstreamed.
        #
        # The patch makes a plain left-click on empty background dismiss the
        # drawer (macOS Launchpad style); upstream only closes on right-click
        # or Escape. Patches only main.go, so the vendorHash is unaffected.
        nwg-drawer = prev.nwg-drawer.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/nwg-drawer-click-outside-to-close.patch
          ];
          preInstall = (old.preInstall or "") + ''
            cp -r img $out/share/nwg-drawer/
          '';
        });

        # Two ProtonVPN tray fixes, both targeted at upstream:
        #   * 0004 re-registers the SNI item when the tray host restarts.
        #     Without it the icon disappears whenever the bar reloads.
        #     Tracked at <https://github.com/ProtonVPN/proton-vpn-gtk-app/pull/157>.
        #   * 0008 makes the DBusMenu GetLayout children spec-conformant
        #     (`av` of variants). The current upstream form is `a(ia{sv}av)`,
        #     which crashes strict DBusMenu readers with a GVariant assertion
        #     the moment the menu is read.
        # Drop both as soon as the equivalent PRs land in nixpkgs's proton-vpn.
        proton-vpn = prev.proton-vpn.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/upstream/0004-reregister-tray-item-when-host-restarts.patch
            ./patches/upstream/0008-dbusmenu-children-as-variants.patch
          ];
        });

        filen-desktop = prev.filen-desktop.overrideAttrs (old: {
          postFixup = (old.postFixup or "") + ''
            ${prev.python3}/bin/python <<PY
            from pathlib import Path

            index_path = Path("${placeholder "out"}/lib/node_modules/@filen/desktop/dist/index.js")
            text = index_path.read_text()

            # Filen enables Electron's local Crashpad database even though it
            # never uploads reports. On Electron 41 an Exit-triggered crash can
            # make systemd-coredump stream tens of gigabytes from Electron's
            # sparse address space, saturating the disk for several minutes.
            old_crash_reporter = """        electron_1.crashReporter.start({\n            submitURL: undefined,\n            productName: \"io.filen.desktop\",\n            uploadToServer: false,\n            ignoreSystemCrashHandler: false,\n            rateLimit: false,\n            compress: false,\n            globalExtra: {\n                cpus: os_1.default.cpus().length.toString(),\n                ram: os_1.default.totalmem().toString(),\n                platform: os_1.default.platform(),\n                release: os_1.default.release()\n            }\n        });"""
            new_crash_reporter = """        // Local crash reporting disabled by the NixOS overlay."""

            old_minimize = """        (_c = this.driveWindow) === null || _c === void 0 ? void 0 : _c.on(\"minimize\", () => {\n            var _a;\n            if (process.platform === \"darwin\" && this.minimizeToTray) {\n                (_a = electron_1.app === null || electron_1.app === void 0 ? void 0 : electron_1.app.dock) === null || _a === void 0 ? void 0 : _a.hide();\n            }\n        });"""
            new_minimize = """        (_c = this.driveWindow) === null || _c === void 0 ? void 0 : _c.on(\"minimize\", e => {\n            var _a, _b;\n            if (this.minimizeToTray) {\n                if (process.platform === \"darwin\") {\n                    (_a = electron_1.app === null || electron_1.app === void 0 ? void 0 : electron_1.app.dock) === null || _a === void 0 ? void 0 : _a.hide();\n                }\n                else {\n                    e.preventDefault();\n                    (_b = this.driveWindow) === null || _b === void 0 ? void 0 : _b.hide();\n                    return;\n                }\n            }\n        });"""

            old_close = """        (_e = this.driveWindow) === null || _e === void 0 ? void 0 : _e.on(\"close\", e => {\n            var _a, _b, _c;\n            if ((process.platform === \"darwin\" || this.minimizeToTray) && !((_a = this.driveWindow) === null || _a === void 0 ? void 0 : _a.isMinimized()) && !this.shouldExitOnQuit) {\n                e.preventDefault();\n                (_b = this.driveWindow) === null || _b === void 0 ? void 0 : _b.minimize();\n                if (process.platform === \"darwin\" && this.minimizeToTray) {\n                    (_c = electron_1.app === null || electron_1.app === void 0 ? void 0 : electron_1.app.dock) === null || _c === void 0 ? void 0 : _c.hide();\n                }\n            }\n        });"""
            new_close = """        (_e = this.driveWindow) === null || _e === void 0 ? void 0 : _e.on(\"close\", e => {\n            var _a, _b, _c;\n            if ((process.platform === \"darwin\" || this.minimizeToTray) && !((_a = this.driveWindow) === null || _a === void 0 ? void 0 : _a.isMinimized()) && !this.shouldExitOnQuit) {\n                e.preventDefault();\n                if (process.platform === \"darwin\") {\n                    (_b = this.driveWindow) === null || _b === void 0 ? void 0 : _b.minimize();\n                    if (this.minimizeToTray) {\n                        (_c = electron_1.app === null || electron_1.app === void 0 ? void 0 : electron_1.app.dock) === null || _c === void 0 ? void 0 : _c.hide();\n                    }\n                }\n                else {\n                    this.driveWindow.hide();\n                }\n            }\n        });"""
            old_init = """            const options = await this.options.get();\n            await electron_1.app.whenReady();"""
            new_init = """            const options = await this.options.get();\n            this.minimizeToTray = options.minimizeToTray ?? false;\n            await electron_1.app.whenReady();"""

            if old_crash_reporter not in text or old_minimize not in text or old_close not in text or old_init not in text:
                raise SystemExit("filen-desktop patch anchors not found")

            text = text.replace(old_crash_reporter, new_crash_reporter)
            text = text.replace(old_init, new_init)
            text = text.replace(old_minimize, new_minimize)
            text = text.replace(old_close, new_close)
            index_path.write_text(text)

            ipc_path = Path("${placeholder "out"}/lib/node_modules/@filen/desktop/dist/ipc/index.js")
            ipc_text = ipc_path.read_text()

            old_ipc_minimize = """        electron_1.ipcMain.handle(\"minimizeWindow\", async () => {\n            var _a;\n            (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.minimize();\n        });"""
            new_ipc_minimize = """        electron_1.ipcMain.handle(\"minimizeWindow\", async () => {\n            var _a, _b;\n            if (this.desktop.minimizeToTray) {\n                (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.hide();\n                return;\n            }\n            (_b = this.desktop.driveWindow) === null || _b === void 0 ? void 0 : _b.minimize();\n        });"""

            old_ipc_close = """        electron_1.ipcMain.handle(\"closeWindow\", async () => {\n            var _a;\n            (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.close();\n        });"""
            new_ipc_close = """        electron_1.ipcMain.handle(\"closeWindow\", async () => {\n            var _a, _b;\n            if (this.desktop.minimizeToTray) {\n                (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.hide();\n                return;\n            }\n            (_b = this.desktop.driveWindow) === null || _b === void 0 ? void 0 : _b.close();\n        });"""

            if old_ipc_minimize not in ipc_text or old_ipc_close not in ipc_text:
                raise SystemExit("filen-desktop ipc patch anchors not found")

            ipc_text = ipc_text.replace(old_ipc_minimize, new_ipc_minimize)
            ipc_text = ipc_text.replace(old_ipc_close, new_ipc_close)
            ipc_path.write_text(ipc_text)

            status_path = Path("${placeholder "out"}/lib/node_modules/@filen/desktop/dist/lib/status.js")
            status_text = status_path.read_text()

            old_open = """                {\n                    label: \"Open\",\n                    type: \"normal\",\n                    click: () => {\n                        this.desktop.showOrOpenDriveWindow();\n                    }\n                },\n                {\n                    label: \"Separator\",\n                    type: \"separator\"\n                },"""
            new_open = """                {\n                    label: \"Open\",\n                    type: \"normal\",\n                    click: () => {\n                        this.desktop.showOrOpenDriveWindow();\n                    }\n                },\n                {\n                    label: \"Hide\",\n                    type: \"normal\",\n                    click: () => {\n                        var _a;\n                        (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.hide();\n                    }\n                },\n                {\n                    label: \"Separator\",\n                    type: \"separator\"\n                },"""

            old_exit = """                    click: () => {\n                        electron_1.app === null || electron_1.app === void 0 ? void 0 : electron_1.app.exit(0);\n                    }"""
            new_exit = """                    click: () => {\n                        this.desktop.shouldExitOnQuit = true;\n                        electron_1.app === null || electron_1.app === void 0 ? void 0 : electron_1.app.exit(0);\n                    }"""

            if old_open not in status_text or old_exit not in status_text:
                raise SystemExit("filen-desktop status patch anchor not found")

            status_text = status_text.replace(old_open, new_open)
            status_text = status_text.replace(old_exit, new_exit)
            status_path.write_text(status_text)
            PY
          '';
        });

        megasync = prev.megasync.overrideAttrs (old:
          let
            appSrc = prev.fetchFromGitHub {
              owner = "dragonleopardpig";
              repo = "MEGAsync";
              rev = "742448b50a1feb0e23e013b325c65ad9b980d5a0";
              hash = "sha256-UITUrAAfYgoRxVLu9CZixmRlkXoJY3zYfooIE1kjQB4=";
            };
            sdkSrc = prev.fetchFromGitHub {
              owner = "meganz";
              repo = "sdk";
              rev = "de912523770668d323605a2ee280085cd891c2c5";
              hash = "sha256-ySybl03npZDQK71EB7Ezte5/2caLw+xovivp+55hUPw=";
            };
          in {
            version = "6.2.1-742448b";
            src = prev.runCommand "megasync-6.2.1-742448b-source" { } ''
              cp -r ${appSrc} $out
              chmod -R +w $out
              mkdir -p $out/src/MEGASync/mega
              cp -r ${sdkSrc}/. $out/src/MEGASync/mega
              chmod -R +w $out/src/MEGASync/mega
            '';

            patches = (old.patches or [ ]) ++ [
              ./patches/megasync-hyprland.patch
              ./patches/megasync-sync-header-labels.patch
            ];

            postPatch = ''
              substituteInPlace src/MEGASync/mega/cmake/modules/sdklib_libraries.cmake \
                --replace-fail "target_link_libraries(SDKlib PRIVATE ICU::i18n ICU::uc ICU::data)" \
                                "target_link_libraries(SDKlib PUBLIC ICU::i18n ICU::uc ICU::data)" \
                --replace-fail "target_link_libraries(SDKlib PRIVATE ICU::uc ICU::data)" \
                                "target_link_libraries(SDKlib PUBLIC ICU::uc ICU::data)"

              ${prev.python3}/bin/python <<'PY'
              from pathlib import Path
              path = Path("src/MEGASync/CMakeLists.txt")
              text = path.read_text()
              if "find_package(ICU COMPONENTS i18n uc data REQUIRED)" not in text:
                  text = text.replace(
                      "target_link_libraries(MEGAsync",
                      "find_package(ICU COMPONENTS i18n uc data REQUIRED)\n\ntarget_link_libraries(MEGAsync",
                      1,
                  )
              marker = "    Qt5::QuickWidgets"
              replacement = "    Qt5::QuickWidgets\n    ICU::i18n\n    ICU::uc\n    ICU::data"
              if replacement not in text:
                  text = text.replace(marker, replacement, 1)
              path.write_text(text)
              PY

              for file in $(find src/ -type f \( -iname configure -o -iname \*.sh \) ); do
                substituteInPlace "$file" --replace-warn "/bin/bash" "${prev.stdenv.shell}"
              done
            '';

            buildInputs = (old.buildInputs or [ ]) ++ (with prev; [
              dbus
              glib
              gtk3
              libappindicator-gtk3
              libnotify
              libx11
              libxext
              libxfixes
              libxrender
            ]);

            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              (prev.lib.cmakeBool "ENABLE_ISOLATED_GFX" false)
            ];
          });
      };

      mkSystem = hostModule: nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          {
            nixpkgs.overlays = [
              inputs.formulaocr-offline.overlays.default
              localOverlay
            ];
          }
          ./configuration.nix
          hostModule
          disko.nixosModules.disko
          grub2-themes.nixosModules.default
          home-manager.nixosModules.home-manager
          {
            home-manager.backupFileExtension = "bak";
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            home-manager.users.thinky = {
              imports = [
                ./home.nix
              ];
            };
            home-manager.extraSpecialArgs = { inherit inputs; };
          }
        ];
      };
    in {
      # X299 Desktop Configuration
      nixosConfigurations.X299 = mkSystem ./hosts/X299;

      # X299 Desktop (external SSD clone)
      nixosConfigurations.X299-SSD = mkSystem ./hosts/X299-SSD;

      # M90aPro Laptop Configuration
      nixosConfigurations.M90aPro = mkSystem ./hosts/M90aPro;

      # Portable SSD — boots on any x86_64 UEFI machine
      nixosConfigurations.PortableSSD = mkSystem ./hosts/PortableSSD;

      # Standalone home-manager configurations (optional)
      homeConfigurations."thinky@X299" = home-manager.lib.homeManagerConfiguration {
        # you need this line
        extraSpecialArgs = { inherit inputs; };
        modules = [
          ./home.nix
        ];
      };

      homeConfigurations."thinky@M90aPro" = home-manager.lib.homeManagerConfiguration {
        # you need this line
        extraSpecialArgs = { inherit inputs; };
        modules = [
          ./home.nix
        ];
      };
    };
}
