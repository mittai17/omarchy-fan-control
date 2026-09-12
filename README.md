# Fan & Thermal Control (Omarchy Shell Plugin)

An advanced fan speed and thermal control plugin for [Omarchy](https://omarchy.org/) (Quickshell) designed for laptops and desktops.

It provides real-time telemetry for CPU and GPU fans, instant 3-level quick mode switching, custom manual speed sliders, and intelligent closed-loop temperature auto-regulation to maintain system temperatures within a normal, safe range.

## Features

- 󰈐 **Universal Hardware Support**:
  - Automatically detects CPU and GPU/chassis fans (`fan1_input`, `fan2_input`, etc.) from Linux `hwmon` sysfs.
  - Supports ACPI platform profiles (`powerprofilesctl` / `/sys/firmware/acpi/platform_profile`) across HP, Lenovo, ASUS, Dell, Framework, and generic Linux systems.
  - Supports direct hardware PWM duty control on desktop motherboards and controllable laptop fan interfaces.
  - Reads CPU package & core thermals (`coretemp`, `k10temp`, `zenpower`, ACPI thermal zones) and discrete GPU temperatures (NVIDIA / AMD).
- ⚡ **3 Simple Levels (Quick Presets)**:
  - **󰌪 Eco**: Low fan noise, power-saver thermal mode, minimal RPM, quiet acoustics for office work and battery saving.
  - **󰓅 Medium**: Balanced fan curve and power profile for everyday multitasking.
  - **󰓦 Max Turbo**: 100% cooling duty and performance profile for intense gaming, compiling, and heavy workloads.
- 🎛️ **Manual Speed Control ("Our Own Speed")**:
  - Interactive slider from **15% to 100%** fan duty.
  - Quick-jump preset chips: `25%`, `50%`, `75%`, `100%`.
  - Sets exact fan PWM duty (where hardware permits) and switches system power profiles dynamically.
- 🌡️ **Smart Temperature Auto-Regulation ("Maintain Normal Temp")**:
  - Configurable **Target Normal Temperature** slider (45°C - 75°C, default 60°C).
  - Built-in closed-loop regulator actively monitors thermals every 2 seconds:
    - If temperature exceeds Target + 2°C: Automatically elevates cooling to actively bring temperatures back down to target.
    - If temperature reaches Critical (>= 80°C): Triggers emergency Max Turbo cooling to protect hardware.
    - If temperature cools down to <= Target - 4°C: Automatically relaxes fan duty into quiet Eco mode.
    - Built-in hysteresis prevents noisy cycling and fan hunting.
- 🖥️ **Status Bar Telemetry**:
  - Live bar readout: `󰈐 3.6k/3.3k · 54°C` (primary fan, secondary fan, CPU temperature).
  - Dynamic color coding:
    - Subtle Cyan: Eco mode
    - Theme Foreground: Normal / Balanced
    - Orange: Elevated thermals (> 68°C)
    - Urgent Red: Critical thermals (>= 80°C)
  - Left-click: Toggles interactive popup panel.
  - Right-click: Quick-cycles through presets (`Eco` → `Medium` → `Max` → `Auto`).
  - Hover: Shows detailed multi-line tooltip with dual fan RPMs and temperatures.

## CLI & IPC Usage

You can control and query the plugin directly from terminal or scripts:

```bash
# View JSON status with all fans, thermals, and current mode
~/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py status

# Switch to Eco mode
~/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py set-mode eco

# Switch to Medium (Balanced) mode
~/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py set-mode medium

# Switch to Max Turbo mode
~/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py set-mode max

# Set manual fan speed percentage (e.g. 75%)
~/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py set-speed 75

# Set target normal temperature auto-regulation (e.g. 60°C)
~/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py set-auto 60

# Shell IPC Toggle
omarchy-shell io.github.mittai17.fan-control toggle
```

## Bar Layout Configuration

The widget is placed on the Omarchy status bar:

```bash
# Place on the bar
omarchy bar put io.github.mittai17.fan-control --after io.github.grootaiinfinity.hwmon

# Move section if desired
omarchy bar move io.github.mittai17.fan-control --section right
```

## License

MIT
