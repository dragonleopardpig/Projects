import sys
from pathlib import Path
app = Path(sys.argv[1])

def edit(path, pairs, what):
    text = path.read_text()
    for old, new in pairs:
        if text.count(old) != 1:
            raise SystemExit(f"filen-desktop {what} anchor not found once ({text.count(old)}): {old[:60]!r}")
        text = text.replace(old, new)
    path.write_text(text)

# Filen enables Electron's local Crashpad database even though it never uploads reports. On
# Electron an Exit-triggered crash can make systemd-coredump stream tens of gigabytes from
# Electron's sparse address space, saturating the disk for several minutes.
crash = ("""        electron_1.crashReporter.start({
            submitURL: undefined,
            productName: "io.filen.desktop",
            uploadToServer: false,
            ignoreSystemCrashHandler: false,
            rateLimit: false,
            compress: false,
            globalExtra: {
                cpus: os_1.default.cpus().length.toString(),
                ram: os_1.default.totalmem().toString(),
                platform: os_1.default.platform(),
                release: os_1.default.release()
            }
        });""", """        // Local crash reporting disabled by the NixOS overlay.""")
# Tray mode is known from the start, not only once the renderer reports it.
init = ("""            const options = await this.options.get();
            await electron_1.app.whenReady();""", """            const options = await this.options.get();
            this.minimizeToTray = options.minimizeToTray ?? false;
            await electron_1.app.whenReady();""")
# Linux in tray mode: closing hides to the tray (upstream minimizes).
close = ("""                e.preventDefault();
                (_d = this.driveWindow) === null || _d === void 0 ? void 0 : _d.minimize();
            }
        });""", """                e.preventDefault();
                (_d = this.driveWindow) === null || _d === void 0 ? void 0 : _d.hide();
            }
        });""")
# ... and so does minimizing.
minimize = ("""        // Open links in default external browser.""", """        // NixOS overlay: in tray mode, minimizing hides to the tray on Linux, like closing.
        this.driveWindow?.on("minimize", () => {
            if (process.platform !== "darwin" && this.minimizeToTray) {
                this.driveWindow?.hide();
            }
        });
        // Open links in default external browser.""")
edit(app / "dist/index.js", [crash, init, close, minimize], "main")

ipc = [("""        electron_1.ipcMain.handle("minimizeWindow", async () => {
            var _a;
            (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.minimize();
        });""", """        electron_1.ipcMain.handle("minimizeWindow", async () => {
            var _a, _b;
            if (this.desktop.minimizeToTray) {
                (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.hide();
                return;
            }
            (_b = this.desktop.driveWindow) === null || _b === void 0 ? void 0 : _b.minimize();
        });"""), ("""        electron_1.ipcMain.handle("closeWindow", async () => {
            var _a;
            (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.close();
        });""", """        electron_1.ipcMain.handle("closeWindow", async () => {
            var _a, _b;
            if (this.desktop.minimizeToTray) {
                (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.hide();
                return;
            }
            (_b = this.desktop.driveWindow) === null || _b === void 0 ? void 0 : _b.close();
        });""")]
edit(app / "dist/ipc/index.js", ipc, "ipc")

hide = [("""                {
                    label: "Open",
                    type: "normal",
                    click: () => {
                        this.desktop.showOrOpenDriveWindow();
                    }
                },""", """                {
                    label: "Open",
                    type: "normal",
                    click: () => {
                        this.desktop.showOrOpenDriveWindow();
                    }
                },
                {
                    label: "Hide",
                    type: "normal",
                    click: () => {
                        var _a;
                        (_a = this.desktop.driveWindow) === null || _a === void 0 ? void 0 : _a.hide();
                    }
                },""")]
edit(app / "dist/lib/status.js", hide, "tray menu")
print("filen-desktop: edits applied")
