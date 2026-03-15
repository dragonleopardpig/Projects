import ast, subprocess, re

  def gdbus(*args):
      return subprocess.check_output(["gdbus"] + list(args), text=True).strip()

  raw = gdbus(
      "call", "--session",
      "--dest", "org.kde.StatusNotifierWatcher",
      "--object-path", "/StatusNotifierWatcher",
      "--method", "org.freedesktop.DBus.Properties.Get",
      "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"
  )

  # Extract the list from the variant
  m = re.search(r"\[(.*)\]", raw)
  items = ast.literal_eval("[" + m.group(1) + "]") if m else []
  print("Items:", items)

  def prop(bus, path, prop):
      try:
          return gdbus(
              "call", "--session",
              "--dest", bus,
              "--object-path", path,
              "--method", "org.freedesktop.DBus.Properties.Get",
              "org.kde.StatusNotifierItem", prop
          )
      except Exception as e:
          return f"ERROR: {e}"

  for item in items:
      bus, path = item.split("/", 1)
      path = "/" + path
      print("\nITEM:", item)
      print("  Id     =", prop(bus, path, "Id"))
      print("  Title  =", prop(bus, path, "Title"))
      print("  Icon   =", prop(bus, path, "IconName"))
      print("  Status =", prop(bus, path, "Status"))
