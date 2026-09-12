#!/bin/bash
set -e

echo "Configuring fan and PWM hardware permissions for Omarchy..."

cat << 'EOF' > /etc/udev/rules.d/99-fancontrol.rules
# Allow user/wheel fan and thermal profile control
KERNEL=="hwmon*", SUBSYSTEM=="hwmon", RUN+="/bin/chmod 0666 /sys/class/hwmon/hwmon*/pwm* 2>/dev/null || true"
ACTION=="add|change", SUBSYSTEM=="hwmon", RUN+="/bin/chmod 0666 /sys/class/hwmon/hwmon*/pwm* 2>/dev/null || true"
EOF

udevadm control --reload-rules && udevadm trigger || true
chmod 0666 /sys/class/hwmon/hwmon*/pwm* 2>/dev/null || true

echo "Fan permissions configured successfully! /sys/class/hwmon/*/pwm* is now accessible."
