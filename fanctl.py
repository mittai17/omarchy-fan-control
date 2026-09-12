#!/usr/bin/env python3
"""
fanctl.py - Hardware Fan & Thermal Controller Backend for Omarchy
Supports laptops (HP, Lenovo, ASUS, Dell, etc.) and desktops.
Provides:
  - 3 Simple Levels: Eco, Medium, Max
  - Manual Speed Control (0-100%)
  - Smart Closed-Loop Temperature Auto-Regulation ("Maintain Normal Temp")
"""

import sys
import os
import glob
import json
import subprocess
import time
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "omarchy"
CONFIG_FILE = CONFIG_DIR / "fan-control.json"

DEFAULT_CONFIG = {
    "mode": "auto",           # "eco", "medium", "max", "manual", "auto"
    "manual_speed": 60,      # 0 - 100%
    "target_temp": 60,       # Target normal temperature in Celsius
    "hysteresis": 3,         # Temperature hysteresis band in Celsius
    "crit_temp": 80,         # Emergency Max Turbo threshold
    "last_applied_mode": "balanced"
}

def load_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
                cfg = DEFAULT_CONFIG.copy()
                cfg.update(data)
                return cfg
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()

def save_config(cfg):
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception as e:
        print(f"Error saving config: {e}", file=sys.stderr)

def get_platform_profile():
    # Try powerprofilesctl first
    try:
        res = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True, timeout=2)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass

    # Fallback to sysfs
    try:
        p = Path("/sys/firmware/acpi/platform_profile")
        if p.exists():
            return p.read_text().strip()
    except Exception:
        pass

    return "unknown"

def set_platform_profile(profile):
    """Sets system thermal/fan platform profile via powerprofilesctl or sysfs."""
    # Profile mapping for powerprofilesctl: power-saver, balanced, performance
    target_ppc = "balanced"
    if profile in ("power-saver", "quiet", "cool", "eco"):
        target_ppc = "power-saver"
    elif profile in ("performance", "max", "turbo"):
        target_ppc = "performance"
    else:
        target_ppc = "balanced"

    # Try powerprofilesctl
    try:
        res = subprocess.run(["powerprofilesctl", "set", target_ppc], capture_output=True, text=True, timeout=2)
        if res.returncode == 0:
            return True
    except Exception:
        pass

    # Try direct sysfs if powerprofilesctl failed
    p = Path("/sys/firmware/acpi/platform_profile")
    if p.exists():
        for candidate in [profile, target_ppc, "quiet" if target_ppc == "power-saver" else target_ppc]:
            try:
                p.write_text(candidate)
                return True
            except Exception:
                pass
    return False

def get_pwm_controllers():
    """Detect any direct hardware PWM fan controls in sysfs (common on desktops)."""
    pwms = []
    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        for pwm_file in sorted(glob.glob(f"{hw}/pwm[1-9]")):
            enable_file = f"{pwm_file}_enable"
            is_writable = os.access(pwm_file, os.W_OK)
            pwms.append({
                "pwm_file": pwm_file,
                "enable_file": enable_file if os.path.exists(enable_file) else None,
                "writable": is_writable
            })
    return pwms

def set_hardware_pwm(pct):
    """Set raw PWM duty cycle (0-255) if hardware allows it."""
    pwms = get_pwm_controllers()
    if not pwms:
        return False
    val = max(0, min(255, int(pct * 2.55)))
    success = False
    for p in pwms:
        if p["writable"]:
            try:
                if p["enable_file"] and os.access(p["enable_file"], os.W_OK):
                    with open(p["enable_file"], "w") as f:
                        f.write("1\n") # 1 = manual control
                with open(p["pwm_file"], "w") as f:
                    f.write(f"{val}\n")
                success = True
            except Exception:
                pass
    return success

def read_fans():
    """Read all detected fan inputs and label them intelligently."""
    fans = []
    hp_fans = []
    other_fans = []

    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        hw_name = "unknown"
        name_path = Path(hw) / "name"
        if name_path.exists():
            try:
                hw_name = name_path.read_text().strip()
            except Exception:
                pass

        for fan_input in sorted(glob.glob(f"{hw}/fan[1-9]*_input")):
            fid = os.path.basename(fan_input).replace("_input", "")
            rpm = 0
            try:
                with open(fan_input, "r") as f:
                    rpm = int(f.read().strip())
            except Exception:
                rpm = 0

            # Determine label
            label = fid
            label_file = fan_input.replace("_input", "_label")
            if os.path.exists(label_file):
                try:
                    with open(label_file, "r") as f:
                        label = f.read().strip()
                except Exception:
                    pass
            elif "hp" in hw_name.lower():
                label = "CPU Fan" if "1" in fid else "GPU Fan"
            elif "thinkpad" in hw_name.lower() or "dell" in hw_name.lower():
                label = "System Fan" if "1" in fid else f"Fan {fid}"
            elif "coretemp" in hw_name.lower() or "nct" in hw_name.lower() or "it87" in hw_name.lower():
                label = f"Chassis {fid}"

            item = {
                "hw_name": hw_name,
                "id": fid,
                "label": label,
                "rpm": rpm,
                "path": fan_input
            }
            if "hp" in hw_name.lower():
                hp_fans.append(item)
            else:
                other_fans.append(item)

    # Prioritize active/vendor fans
    all_fans = hp_fans + other_fans
    # Filter out inactive zero-RPM duplicate dummy fans if active fans exist
    active_fans = [f for f in all_fans if f["rpm"] > 0]
    result = active_fans if active_fans else all_fans
    return result

def read_temperatures():
    """Read temperatures from CPU, GPU, NVMe, and thermal zones."""
    cpu_temp = None
    gpu_temp = None
    max_temp = 0.0
    temps = []

    # 1. Hwmon thermal sensors
    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        hw_name = "unknown"
        name_path = Path(hw) / "name"
        if name_path.exists():
            try:
                hw_name = name_path.read_text().strip()
            except Exception:
                pass

        for tinput in sorted(glob.glob(f"{hw}/temp[1-9]*_input")):
            tid = os.path.basename(tinput).replace("_input", "")
            try:
                with open(tinput, "r") as f:
                    celsius = float(f.read().strip()) / 1000.0
            except Exception:
                continue

            if celsius < 0 or celsius > 150: # Sanity filter
                continue

            label = tid
            label_file = tinput.replace("_input", "_label")
            if os.path.exists(label_file):
                try:
                    with open(label_file, "r") as f:
                        label = f.read().strip()
                except Exception:
                    pass

            temps.append({"hw": hw_name, "label": label, "temp": round(celsius, 1)})
            if celsius > max_temp:
                max_temp = celsius

            # Identify CPU
            if hw_name in ("coretemp", "k10temp", "zenpower") or "Package id 0" in label or "x86_pkg_temp" in label:
                if cpu_temp is None or "Package id 0" in label:
                    cpu_temp = round(celsius, 1)

            # Identify GPU
            if "gpu" in hw_name.lower() or "amdgpu" in hw_name.lower() or "nouveau" in hw_name.lower():
                if gpu_temp is None or "edge" in label.lower():
                    gpu_temp = round(celsius, 1)

    # 2. NVIDIA GPU via nvidia-smi if discrete GPU present
    if gpu_temp is None:
        try:
            res = subprocess.run(
                ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=1
            )
            if res.returncode == 0 and res.stdout.strip():
                gpu_temp = float(res.stdout.strip().split("\n")[0])
                if gpu_temp > max_temp:
                    max_temp = gpu_temp
        except Exception:
            pass

    # 3. Fallback from thermal zones if CPU temp wasn't matched
    if cpu_temp is None:
        for tz in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
            try:
                with open(f"{tz}/temp", "r") as f:
                    val = float(f.read().strip()) / 1000.0
                with open(f"{tz}/type", "r") as f:
                    ttype = f.read().strip()
                if "x86_pkg_temp" in ttype or "acpitz" in ttype:
                    cpu_temp = round(val, 1)
                    break
            except Exception:
                pass

    if cpu_temp is None and temps:
        cpu_temp = temps[0]["temp"]
    if cpu_temp is None:
        cpu_temp = 50.0

    return {
        "cpu_temp": cpu_temp,
        "gpu_temp": gpu_temp,
        "max_temp": round(max_temp if max_temp > 0 else cpu_temp, 1),
        "sensors": temps
    }

def apply_mode(mode_name, manual_speed=60):
    """
    Applies fan & power state according to the requested mode:
      - 'eco': Whisper quiet / power saver, minimal fan RPM
      - 'medium': Balanced cooling for everyday use
      - 'max': 100% full fan cooling / turbo performance
      - 'manual': Custom user-chosen percentage
    """
    if mode_name == "eco":
        set_platform_profile("power-saver")
        set_hardware_pwm(25)
        return "power-saver"
    elif mode_name == "medium":
        set_platform_profile("balanced")
        set_hardware_pwm(55)
        return "balanced"
    elif mode_name == "max":
        set_platform_profile("performance")
        set_hardware_pwm(100)
        return "performance"
    elif mode_name == "manual":
        # Map manual speed percentage
        pct = max(0, min(100, int(manual_speed)))
        if pct < 35:
            profile = "power-saver"
        elif pct <= 75:
            profile = "balanced"
        else:
            profile = "performance"
        set_platform_profile(profile)
        set_hardware_pwm(pct)
        return profile
    return "balanced"

def evaluate_smart_auto(cfg, current_temp):
    """
    Smart Closed-Loop Temperature Maintainer:
    Keeps temperature around target_temp (default 60°C).
    Uses hysteresis to prevent oscillating.
    """
    target = cfg.get("target_temp", 60)
    crit = cfg.get("crit_temp", 80)
    last_mode = cfg.get("last_applied_mode", "balanced")

    # Critical thermal threshold: force Max Turbo
    if current_temp >= crit:
        apply_mode("max")
        cfg["last_applied_mode"] = "performance"
        save_config(cfg)
        return {
            "action": "emergency_max",
            "reason": f"High temperature alert ({current_temp}°C >= {crit}°C). Maximum cooling active.",
            "applied_profile": "performance",
            "state": "Critical"
        }

    # Temperature above target + 2°C: Ramp up cooling
    if current_temp > (target + 2):
        if current_temp > (target + 10):
            apply_mode("max")
            cfg["last_applied_mode"] = "performance"
            status_desc = f"Temperature elevated ({current_temp}°C). Turbo cooling engaged to restore {target}°C."
            applied = "performance"
            state = "Cooling"
        else:
            apply_mode("medium")
            cfg["last_applied_mode"] = "balanced"
            status_desc = f"Temperature slightly warm ({current_temp}°C). Balanced cooling active."
            applied = "balanced"
            state = "Normal"
        save_config(cfg)
        return {
            "action": "cool_down",
            "reason": status_desc,
            "applied_profile": applied,
            "state": state
        }

    # Temperature comfortably below target - 4°C: Relax fans to quiet/eco
    if current_temp <= (target - 4):
        apply_mode("eco")
        cfg["last_applied_mode"] = "power-saver"
        save_config(cfg)
        return {
            "action": "eco_relax",
            "reason": f"System is cool ({current_temp}°C <= {target - 4}°C). Quiet Eco cooling engaged.",
            "applied_profile": "power-saver",
            "state": "Eco"
        }

    # Within normal band: keep balanced
    if last_mode != "balanced":
        apply_mode("medium")
        cfg["last_applied_mode"] = "balanced"
        save_config(cfg)
    return {
        "action": "maintain_normal",
        "reason": f"Temperature is in normal target range ({current_temp}°C ≈ {target}°C).",
        "applied_profile": "balanced",
        "state": "Normal"
    }

def get_status():
    cfg = load_config()
    fans = read_fans()
    thermals = read_temperatures()
    profile = get_platform_profile()

    # Identify primary and secondary fan
    primary_fan = fans[0] if fans else {"label": "Fan 1", "rpm": 0}
    secondary_fan = fans[1] if len(fans) > 1 else None

    # Calculate estimated fan percentage (assuming ~5500-6000 max RPM standard laptop fan)
    max_estimated_rpm = 5800
    for f in fans:
        f["pct"] = min(100, int((f["rpm"] / max_estimated_rpm) * 100))

    mode = cfg.get("mode", "auto")
    target_temp = cfg.get("target_temp", 60)
    manual_speed = cfg.get("manual_speed", 60)
    cur_temp = thermals["cpu_temp"]

    # Thermal status description
    if cur_temp >= cfg.get("crit_temp", 80):
        thermal_state = "Critical"
        thermal_state_desc = f"Critical Heat: {cur_temp}°C (Emergency Turbo Active)"
    elif mode == "auto":
        auto_eval = evaluate_smart_auto(cfg, cur_temp)
        if cur_temp > target_temp + 2:
            thermal_state = "Cooling"
            thermal_state_desc = f"Cooling Down: {cur_temp}°C -> Target {target_temp}°C"
        elif cur_temp <= target_temp - 4:
            thermal_state = "Quiet"
            thermal_state_desc = f"Cool & Quiet: {cur_temp}°C (Below {target_temp}°C Target)"
        else:
            thermal_state = "Normal"
            thermal_state_desc = f"Normal Temp: {cur_temp}°C (Maintained at ~{target_temp}°C)"
    elif mode == "eco":
        thermal_state = "Eco"
        thermal_state_desc = f"Eco Mode: Quiet acoustics ({cur_temp}°C)"
    elif mode == "medium":
        thermal_state = "Balanced"
        thermal_state_desc = f"Medium Mode: Balanced cooling ({cur_temp}°C)"
    elif mode == "max":
        thermal_state = "Turbo"
        thermal_state_desc = f"Max Mode: 100% cooling power ({cur_temp}°C)"
    elif mode == "manual":
        thermal_state = "Manual"
        thermal_state_desc = f"Manual Control: {manual_speed}% fan speed ({cur_temp}°C)"
    else:
        thermal_state = "Normal"
        thermal_state_desc = f"{cur_temp}°C"

    return {
        "fans": fans,
        "primary_label": primary_fan["label"],
        "primary_rpm": primary_fan["rpm"],
        "primary_pct": primary_fan.get("pct", 0),
        "secondary_label": secondary_fan["label"] if secondary_fan else None,
        "secondary_rpm": secondary_fan["rpm"] if secondary_fan else 0,
        "secondary_pct": secondary_fan.get("pct", 0) if secondary_fan else 0,
        "has_dual_fans": len(fans) >= 2,
        "cpu_temp": thermals["cpu_temp"],
        "gpu_temp": thermals["gpu_temp"],
        "max_temp": thermals["max_temp"],
        "mode": mode,
        "manual_speed": manual_speed,
        "target_temp": target_temp,
        "thermal_state": thermal_state,
        "thermal_state_desc": thermal_state_desc,
        "active_profile": profile,
        "timestamp": int(time.time())
    }

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("status", "json"):
        st = get_status()
        print(json.dumps(st, indent=2))
        return

    cmd = sys.argv[1]

    if cmd == "set-mode":
        if len(sys.argv) < 3:
            print("Usage: fanctl.py set-mode <eco|medium|max|auto|manual>", file=sys.stderr)
            sys.exit(1)
        mode = sys.argv[2].lower()
        if mode not in ("eco", "medium", "max", "auto", "manual"):
            print(f"Unknown mode: {mode}. Use eco, medium, max, auto, or manual.", file=sys.stderr)
            sys.exit(1)

        cfg = load_config()
        cfg["mode"] = mode
        save_config(cfg)

        if mode in ("eco", "medium", "max"):
            apply_mode(mode)
        elif mode == "manual":
            apply_mode("manual", cfg.get("manual_speed", 60))
        elif mode == "auto":
            thermals = read_temperatures()
            evaluate_smart_auto(cfg, thermals["cpu_temp"])

        print(json.dumps({"success": True, "mode": mode}))

    elif cmd == "set-speed":
        if len(sys.argv) < 3:
            print("Usage: fanctl.py set-speed <0-100>", file=sys.stderr)
            sys.exit(1)
        try:
            speed = max(0, min(100, int(sys.argv[2])))
        except ValueError:
            print("Speed must be an integer 0-100", file=sys.stderr)
            sys.exit(1)

        cfg = load_config()
        cfg["mode"] = "manual"
        cfg["manual_speed"] = speed
        save_config(cfg)
        apply_mode("manual", speed)
        print(json.dumps({"success": True, "mode": "manual", "speed": speed}))

    elif cmd == "set-auto":
        target = 60
        if len(sys.argv) >= 3:
            try:
                target = max(40, min(85, int(sys.argv[2])))
            except ValueError:
                target = 60

        cfg = load_config()
        cfg["mode"] = "auto"
        cfg["target_temp"] = target
        save_config(cfg)
        thermals = read_temperatures()
        res = evaluate_smart_auto(cfg, thermals["cpu_temp"])
        print(json.dumps({"success": True, "mode": "auto", "target_temp": target, "result": res}))

    elif cmd == "tick":
        cfg = load_config()
        mode = cfg.get("mode", "auto")
        if mode == "auto":
            thermals = read_temperatures()
            res = evaluate_smart_auto(cfg, thermals["cpu_temp"])
            print(json.dumps({"success": True, "mode": "auto", "evaluation": res}))
        else:
            print(json.dumps({"success": True, "mode": mode, "status": "no_auto_tick_needed"}))

    elif cmd == "daemon":
        # Optional background daemon loop
        print("Starting fanctl thermal maintenance daemon...")
        while True:
            try:
                cfg = load_config()
                if cfg.get("mode") == "auto":
                    thermals = read_temperatures()
                    evaluate_smart_auto(cfg, thermals["cpu_temp"])
            except Exception as e:
                print(f"Daemon error: {e}", file=sys.stderr)
            time.sleep(3)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
