// Nerd Font glyph constants. Source: https://www.nerdfonts.com/cheat-sheet
// Embedded as escape sequences so the file is portable and grep-able.
export const ICON = {
    cpu:        "\u{f4bc}",  // nf-oct-cpu
    memory:     "\u{f035b}", // nf-md-memory
    disk:       "\u{f02d2}", // nf-md-harddisk
    temp:       "\u{f2c8}",  // nf-fa-thermometer
    warning:    "\u{f071}",  // nf-fa-warning
    battery:    "\u{f240}",  // nf-fa-battery_full
    bat_full:   "\u{f240}",  // nf-fa-battery_full
    bat_3q:     "\u{f241}",  // nf-fa-battery_three_quarters
    bat_half:   "\u{f242}",  // nf-fa-battery_half
    bat_1q:     "\u{f243}",  // nf-fa-battery_quarter
    bat_empty:  "\u{f244}",  // nf-fa-battery_empty
    charging:   "\u{f0e7}",  // nf-fa-bolt  (battery charging)
    wifi:       "\u{f1eb}",  // nf-fa-wifi
    ethernet:   "\u{f0200}", // nf-md-ethernet
    nowifi:     "\u{f05aa}", // nf-md-wifi_off
    speaker:    "\u{f028}",  // nf-fa-volume_up
    mute:       "\u{f026}",  // nf-fa-volume_off
    bell:       "\u{f0f3}",  // nf-fa-bell
    bell_slash: "\u{f1f6}",  // nf-fa-bell_slash
    bell_dnd:   "\u{f1f6}",  // reuse bell_slash — newer MD codepoints (F0588) not in CaskaydiaCove
    power:      "\u{f0425}", // nf-md-power
    play:       "\u{f04b}",  // nf-fa-play
    pause:      "\u{f04c}",  // nf-fa-pause
    prev:       "\u{f04a}",  // nf-fa-backward
    next:       "\u{f04e}",  // nf-fa-forward
    music:      "\u{f001}",  // nf-fa-music
    caffeine:   "\u{f0f4}",  // nf-fa-coffee  (idle inhibitor on)
    sleep:      "\u{f04b8}", // nf-md-sleep   (idle inhibitor off)
    mic:        "\u{f130}",  // nf-fa-microphone
    mic_off:    "\u{f131}",  // nf-fa-microphone_slash
    camera:     "\u{f030}",  // nf-fa-camera
    caps:       "\u{f11c}",  // nf-fa-keyboard_o
    lock:       "\u{f023}",  // nf-fa-lock        (secured Wi-Fi)
    check:      "\u{f00c}",  // nf-fa-check       (active connection)
    chevron_dn: "\u{f078}",  // nf-fa-chevron_down
    chevron_up: "\u{f077}",  // nf-fa-chevron_up
    refresh:    "\u{f021}",  // nf-fa-refresh     (rescan)
    close:      "\u{f00d}",  // nf-fa-times       (cancel)
}
