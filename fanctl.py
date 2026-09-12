#!/usr/bin/env python3
"""
fanctl.py - Hardware Fan & Thermal Controller Daemon & CLI for Omarchy
Supports laptops (HP, Lenovo, ASUS, Dell, Framework, etc.) and desktops.
Provides:
  - 3 Simple Levels: Eco, Medium, Max
  - Manual Speed Control (15-100%)
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
STATUS_FILE = CONFIG_DIR / "fan-status.json"

DEFAULT_CONFIG = {
    "mode": "auto",           # "eco", "medium", "max", "manual", "auto"
    "manual_speed": 60,      # 0 - 100%
    "target_temp": 60,       # Target normal temperature in Celsius
    "hysteresis": 2,         # Temperature hysteresis band in Celsius
    "crit_temp": 80,         # Emergency Max Turbo threshold
    "last_applied_mode": "balanced",
    "cooling_active": False
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
    try:
        res = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True, timeout=1)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass

    try:
        p = Path("/sys/firmware/acpi/platform_profile")
        if p.exists():
            return p.read_text().strip()
    except Exception:
        pass

    return "balanced"

def set_platform_profile(profile):
    """Sets system thermal/fan platform profile via omarchy-powerprofiles-set or powerprofilesctl."""
    target_ppc = "balanced"
    if profile in ("power-saver", "quiet", "cool", "eco"):
        target_ppc = "power-saver"
    elif profile in ("performance", "max", "turbo"):
        target_ppc = "performance"
    else:
        target_ppc = "balanced"

    try:
        subprocess.run(["omarchy-powerprofiles-set", "ac", target_ppc], capture_output=True, timeout=2)
        subprocess.run(["omarchy-powerprofiles-set", "battery", target_ppc], capture_output=True, timeout=2)
        return True
    except Exception:
        pass

    try:
        res = subprocess.run(["powerprofilesctl", "set", target_ppc], capture_output=True, text=True, timeout=2)
        if res.returncode == 0:
            return True
    except Exception:
        pass

    return False

def get_pwm_controllers():
    """Detect any hardware PWM controls or enable switches in sysfs."""
    controllers = []
    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        for pwm_file in sorted(glob.glob(f"{hw}/pwm[1-9]")):
            enable_file = f"{pwm_file}_enable"
            controllers.append({
                "type": "pwm_duty",
                "file": pwm_file,
                "enable_file": enable_file if os.path.exists(enable_file) else None,
                "writable": os.access(pwm_file, os.W_OK)
            })

        for enable_file in sorted(glob.glob(f"{hw}/pwm[1-9]_enable")):
            base_pwm = enable_file.replace("_enable", "")
            if not os.path.exists(base_pwm):
                controllers.append({
                    "type": "pwm_enable_only",
                    "file": enable_file,
                    "writable": os.access(enable_file, os.W_OK)
                })
    return controllers

def set_hardware_fans(mode_name, pct=60):
    """
    Directly writes to hardware fan controller nodes:
      - HP / ACPI laptops: pwm1_enable: 0 = Max Turbo (100%), 2 = Auto thermal curve
      - Desktop motherboards: pwm[1-9]: 0 - 255
    """
    controllers = get_pwm_controllers()
    if not controllers:
        return False

    success = False
    for c in controllers:
        if c["type"] == "pwm_enable_only":
            enable_file = c["file"]
            try:
                # 0 = Max Turbo (100%), 2 = Auto curve
                target_val = "0\n" if (mode_name == "max" or (mode_name == "manual" and pct >= 80)) else "2\n"
                with open(enable_file, "w") as f:
                    f.write(target_val)
                success = True
            except Exception:
                pass

        elif c["type"] == "pwm_duty":
            val = max(0, min(255, int(pct * 2.55)))
            try:
                if c["enable_file"] and os.access(c["enable_file"], os.W_OK):
                    with open(c["enable_file"], "w") as f:
                        f.write("1\n" if mode_name == "manual" else ("0\n" if mode_name == "max" else "2\n"))
                if c["writable"]:
                    with open(c["file"], "w") as f:
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

    all_fans = hp_fans + other_fans
    active_fans = [f for f in all_fans if f["rpm"] > 0]
    return active_fans if active_fans else all_fans

def read_temperatures():
    """Read temperatures from CPU, GPU, NVMe, and thermal zones."""
    cpu_temp = None
    gpu_temp = None
    max_temp = 0.0
    temps = []

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

            if celsius < 0 or celsius > 150:
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

            # CPU identification
            if hw_name in ("coretemp", "k10temp", "zenpower") or "Package id 0" in label or "x86_pkg_temp" in label:
                if cpu_temp is None or "Package id 0" in label:
                    cpu_temp = round(celsius, 1)

            # GPU identification
            if "gpu" in hw_name.lower() or "amdgpu" in hw_name.lower() or "nouveau" in hw_name.lower():
                if gpu_temp is None or "edge" in label.lower():
                    gpu_temp = round(celsius, 1)

    # NVIDIA GPU fallback
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

    # ACPI thermal zone fallback
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
    Applies fan & power state according to requested mode.
    """
    if mode_name == "eco":
        set_platform_profile("power-saver")
        set_hardware_fans("eco", 25)
        return "power-saver"
    elif mode_name == "medium":
        set_platform_profile("balanced")
        set_hardware_fans("medium", 55)
        return "balanced"
    elif mode_name == "max":
        set_platform_profile("performance")
        set_hardware_fans("max", 100)
        return "performance"
    elif mode_name == "manual":
        pct = max(15, min(100, int(manual_speed)))
        if pct < 35:
            profile = "power-saver"
        elif pct <= 75:
            profile = "balanced"
        else:
            profile = "performance"
        set_platform_profile(profile)
        set_hardware_fans("manual", pct)
        return profile
    return "balanced"

def evaluate_smart_auto(cfg, current_temp):
    """
    Smart Closed-Loop Temperature Maintainer:
    Actively drives fans to keep temperature around target_temp.
    If current_temp exceeds target_temp + 2°C, actively turns on high cooling.
    When temperature drops to target_temp or below, relaxes fans to quiet normal.
    """
    target = cfg.get("target_temp", 60)
    crit = cfg.get("crit_temp", 80)
    cooling_active = cfg.get("cooling_active", False)

    # 1. Critical safety trigger
    if current_temp >= crit:
        apply_mode("max")
        cfg["cooling_active"] = True
        cfg["last_applied_mode"] = "performance"
        save_config(cfg)
        return {
            "action": "emergency_max",
            "reason": f"High temp alert ({current_temp}°C >= {crit}°C). Maximum cooling active.",
            "applied_profile": "performance",
            "state": "Critical"
        }

    # 2. Temperature is HOTTER than target: actively engage cooling
    if current_temp > (target + 2):
        apply_mode("max")
        cfg["cooling_active"] = True
        cfg["last_applied_mode"] = "performance"
        save_config(cfg)
        return {
            "action": "active_cooling",
            "reason": f"Cooling Down: {current_temp}°C (Target {target}°C). Fans boosted to restore normal temp.",
            "applied_profile": "performance",
            "state": "Cooling"
        }

    # 3. If cooling was active and temperature is now safely at or below target: relax cooling
    if cooling_active and current_temp <= (target - 1):
        cfg["cooling_active"] = False
        apply_mode("medium")
        cfg["last_applied_mode"] = "balanced"
        save_config(cfg)
        return {
            "action": "target_restored",
            "reason": f"Normal temp restored ({current_temp}°C <= {target}°C). Fans relaxed.",
            "applied_profile": "balanced",
            "state": "Normal"
        }

    # 4. Temperature is well below target: quiet eco
    if current_temp <= (target - 5):
        apply_mode("eco")
        cfg["last_applied_mode"] = "power-saver"
        save_config(cfg)
        return {
            "action": "eco_quiet",
            "reason": f"Cool & Quiet: {current_temp}°C (Below {target}°C Target). Whisper quiet.",
            "applied_profile": "power-saver",
            "state": "Quiet"
        }

    # 5. Normal steady state
    if not cooling_active:
        apply_mode("medium")
        cfg["last_applied_mode"] = "balanced"
        save_config(cfg)
        return {
            "action": "maintain_normal",
            "reason": f"Normal Temp: {current_temp}°C (Maintained around {target}°C target).",
            "applied_profile": "balanced",
            "state": "Normal"
        }
    else:
        return {
            "action": "cooling_in_progress",
            "reason": f"Cooling Down: {current_temp}°C -> Target {target}°C.",
            "applied_profile": "performance",
            "state": "Cooling"
        }

def get_status():
    cfg = load_config()
    fans = read_fans()
    thermals = read_temperatures()
    profile = get_platform_profile()

    primary_fan = fans[0] if fans else {"label": "Fan 1", "rpm": 0}
    secondary_fan = fans[1] if len(fans) > 1 else None

    max_estimated_rpm = 5800
    for f in fans:
        f["pct"] = min(100, int((f["rpm"] / max_estimated_rpm) * 100))

    mode = cfg.get("mode", "auto")
    target_temp = cfg.get("target_temp", 60)
    manual_speed = cfg.get("manual_speed", 60)
    cur_temp = thermals["cpu_temp"]

    if mode == "auto":
        eval_res = evaluate_smart_auto(cfg, cur_temp)
        thermal_state = eval_res["state"]
        thermal_state_desc = eval_res["reason"]
    elif cur_temp >= cfg.get("crit_temp", 85):
        apply_mode("max")
        thermal_state = "Critical"
        thermal_state_desc = f"Critical Heat: {cur_temp}°C (Emergency Turbo Active)"
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

    controllers = get_pwm_controllers()
    has_pwm_write_access = any(c.get("writable", False) for c in controllers)

    status_obj = {
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
        "has_pwm_write_access": has_pwm_write_access,
        "timestamp": int(time.time())
    }

    # Directly update status file in-place to trigger inotify IN_MODIFY
    try:
        with open(STATUS_FILE, "w") as f:
            json.dump(status_obj, f)
            f.flush()
    except Exception:
        pass

    return status_obj

def run_daemon():
    """Background temperature maintainer loop."""
    print("fanctl daemon started. Actively regulating thermals...", flush=True)
    last_state = None
    while True:
        try:
            st = get_status()
            cur_state = f"mode={st.get('mode')}, temp={st.get('cpu_temp')}C, fans={st.get('primary_rpm')}/{st.get('secondary_rpm')} RPM, state={st.get('thermal_state')}"
            if cur_state != last_state:
                print(f"[{time.strftime('%X')}] {cur_state} ({st.get('thermal_state_desc')})", flush=True)
                last_state = cur_state
        except Exception as e:
            print(f"Daemon error: {e}", file=sys.stderr, flush=True)
        time.sleep(1.5)

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("status", "json"):
        st = get_status()
        print(json.dumps(st))
        return

    cmd = sys.argv[1]

    if cmd == "daemon":
        run_daemon()
        return

    if cmd == "set-mode":
        if len(sys.argv) < 3:
            print("Usage: fanctl.py set-mode <eco|medium|max|auto|manual>", file=sys.stderr)
            sys.exit(1)
        mode = sys.argv[2].lower()
        if mode not in ("eco", "medium", "max", "auto", "manual"):
            print(f"Unknown mode: {mode}", file=sys.stderr)
            sys.exit(1)

        cfg = load_config()
        cfg["mode"] = mode
        cfg["cooling_active"] = False
        save_config(cfg)

        if mode in ("eco", "medium", "max"):
            apply_mode(mode)
        elif mode == "manual":
            apply_mode("manual", cfg.get("manual_speed", 60))
        elif mode == "auto":
            thermals = read_temperatures()
            evaluate_smart_auto(cfg, thermals["cpu_temp"])

        st = get_status()
        print(json.dumps(st))

    elif cmd == "set-speed":
        if len(sys.argv) < 3:
            print("Usage: fanctl.py set-speed <0-100>", file=sys.stderr)
            sys.exit(1)
        try:
            speed = max(15, min(100, int(sys.argv[2])))
        except ValueError:
            print("Speed must be an integer", file=sys.stderr)
            sys.exit(1)

        cfg = load_config()
        cfg["mode"] = "manual"
        cfg["manual_speed"] = speed
        cfg["cooling_active"] = False
        save_config(cfg)
        apply_mode("manual", speed)
        st = get_status()
        print(json.dumps(st))

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
        cfg["cooling_active"] = False
        save_config(cfg)
        thermals = read_temperatures()
        evaluate_smart_auto(cfg, thermals["cpu_temp"])
        st = get_status()
        print(json.dumps(st))

    elif cmd == "tick":
        st = get_status()
        print(json.dumps(st))

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
