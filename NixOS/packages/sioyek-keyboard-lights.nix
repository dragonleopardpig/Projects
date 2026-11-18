{
  lib,
  writeText,
  writeShellScriptBin,
  g810-led,
  solaar,
}:

let
  # Sioyek chooses a highlight type by pressing h followed by a-z. Mirror its
  # default 26-color palette on those letter keys of either Logitech keyboard.
  # The older GPRO (046d:c339) uses g810-led. The PRO X TKL (046d:c352) uses
  # Solaar's supported HID++ PER_KEY_LIGHTING_V2 live update; its per-key data
  # cannot currently be stored in an onboard profile by a Linux tool.
  sioyekHighlightColors = {
    a = "f0a3ff";
    b = "0075db";
    c = "994000";
    d = "4d005c";
    e = "1a1a1a";
    f = "005c30";
    g = "2bcf47";
    h = "ffcc99";
    i = "808080";
    j = "94ffb5";
    k = "8f7d00";
    l = "9ecc00";
    m = "c20087";
    n = "003380";
    o = "ffa305";
    p = "ffa8ba";
    q = "426600";
    r = "ff000f";
    s = "5ef2f2";
    t = "00998f";
    u = "e0ff66";
    v = "730aff";
    w = "990000";
    x = "ffff80";
    y = "ffff00";
    z = "ff4f05";
  };

  sioyekKeyboardProfile = writeText "gpro-sioyek-highlights.profile" (
    "a ffffff\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (key: color: "k ${key} ${color}") sioyekHighlightColors
    )
    + "\nc\n"
  );

  gproLedSioyek = g810-led.override {
    profile = sioyekKeyboardProfile;
  };

  gproSioyekApply = writeShellScriptBin "gpro-sioyek" ''
    exec ${lib.getExe' gproLedSioyek "gpro-led"} -p ${sioyekKeyboardProfile}
  '';

  proXTklSioyekScript = writeText "pro-x-tkl-sioyek.py" ''
    #!/usr/bin/env python3
    import sys
    import time

    from logitech_receiver import exceptions
    from logitech_receiver import hidpp20_constants
    from logitech_receiver import settings_templates
    from solaar.cli import _find_device, _receivers_and_devices


    PALETTE = ${builtins.toJSON sioyekHighlightColors}


    def main():
        devices = list(_receivers_and_devices())
        keyboard = next(
            (device for device in _find_device(devices, "pro x tkl") if device.ping()),
            None,
        )
        if keyboard is None:
            print("PRO X TKL is not connected", file=sys.stderr)
            return 2

        lighting = settings_templates.check_feature_setting(
            keyboard, "per-key-lighting"
        )
        led_control = settings_templates.check_feature_setting(keyboard, "rgb_control")
        if lighting is None or led_control is None:
            print("PRO X TKL lighting features are unavailable", file=sys.stderr)
            return 1

        solaar_control = next(
            choice for choice in led_control.choices if str(choice) == "Solaar"
        )
        device_control = next(
            choice for choice in led_control.choices if str(choice) == "Device"
        )
        current_control = led_control.read(cached=False)
        if current_control is None:
            print("Could not read the keyboard LED controller", file=sys.stderr)
            return 1
        # PER_KEY_LIGHTING_V2 leaves its commit engine busy after one complete
        # palette. Cycling control back through the device starts a fresh
        # update session, making repeated Super+F7 presses reliable.
        if current_control == solaar_control:
            if led_control.write(device_control, save=False) is None:
                print("Could not reset the keyboard LED controller", file=sys.stderr)
                return 1
            time.sleep(0.05)
        if led_control.write(solaar_control, save=False) is None:
            print("Could not give Solaar control of the keyboard LEDs", file=sys.stderr)
            return 1

        keys_by_name = {str(key).lower(): int(key) for key in lighting.choices}
        colors = {int(key): 0xFFFFFF for key in lighting.choices}
        for key, color in PALETTE.items():
            colors[keys_by_name[key]] = int(color, 16)

        try:
            lighting.write(colors, save=False)
        except exceptions.FeatureCallError as error:
            # The wireless keyboard can briefly report BUSY when committing a
            # second palette. Its update buffer is already populated, so retry
            # just the commit instead of sending every key again.
            if (
                error.error != hidpp20_constants.ErrorCode.BUSY
                or error.request & 0xF0 != 0x70
            ):
                raise
            for delay in (0.05, 0.1, 0.25, 0.5, 1.0):
                time.sleep(delay)
                try:
                    keyboard.feature_request(lighting.feature, 0x70, 0x00)
                    break
                except exceptions.FeatureCallError as retry_error:
                    if retry_error.error != hidpp20_constants.ErrorCode.BUSY:
                        raise
            else:
                raise
        print("Applied Sioyek palette to PRO X TKL")
        return 0


    if __name__ == "__main__":
        try:
            raise SystemExit(main())
        except Exception as error:
            print(f"Could not update PRO X TKL lighting: {error}", file=sys.stderr)
            raise SystemExit(1)
  '';

  # Add one batch command to Solaar so the entire keyboard is updated in one
  # HID++ transaction instead of starting the Solaar CLI once per key.
  solaarSioyek = solaar.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      install -Dm755 ${proXTklSioyekScript} $out/bin/pro-x-tkl-sioyek
    '';
  });
in
(writeShellScriptBin "sioyek-keyboard-lights" ''
  if ${solaarSioyek}/bin/pro-x-tkl-sioyek; then
    exit 0
  fi

  exec ${lib.getExe gproSioyekApply}
'').overrideAttrs (old: {
  # Real passthru, so configuration.nix can reach them as
  # sioyekKeyboardApply.gproLed / .gproSioyekApply (a plain
  # `// { passthru.gproLed = ...; }` only makes `.passthru.gproLed`).
  passthru = (old.passthru or { }) // {
    gproLed = gproLedSioyek;
    inherit gproSioyekApply;
  };
})
