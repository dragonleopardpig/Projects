import sys, os

target = """            #[cfg(any(target_os = "linux", target_os = "freebsd"))]
            if self.context_menu.with_untracked(|c| c.is_some()) {
                // we had a pointer up event
                // if context menu is still shown
                // we should hide it
                self.context_menu.set(None);
            }
"""

root_dir = sys.argv[1] if len(sys.argv) > 1 else "/build"
found = False
for root, dirs, files in os.walk(root_dir):
    for f in files:
        if f == "window_handle.rs":
            p = os.path.join(root, f)
            with open(p, "r", encoding="utf-8") as fp:
                c = fp.read()
            if target in c:
                print(f"Patching Floem context menu in {p}")
                os.chmod(p, 0o644)
                with open(p, "w", encoding="utf-8") as fp:
                    fp.write(c.replace(target, ""))
                found = True

if not found:
    print(f"Warning: target context menu block not found in {root_dir}")
