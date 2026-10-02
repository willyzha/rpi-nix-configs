import re

with open('modules/common.nix', 'r') as f:
    content = f.read()

watchdog_config = """
  # Hardware Watchdog & Auto-Reboot on Kernel Panic
  # BCM2835 WDT has a strict 15-second maximum timeout.
  systemd.watchdog.runtimeTime = "14s"; # systemd will ping the WDT every 7s
  systemd.watchdog.rebootTime = "14s";
  systemd.watchdog.kexecTime = "14s";
"""

sysctls = """
    # Auto-reboot safely on kernel panics (e.g. RCU starvation or soft lockups) instead of freezing forever
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;
    "kernel.softlockup_panic" = 1;
    "kernel.hung_task_panic" = 1;
    "kernel.hung_task_timeout_secs" = 120;
    "vm.panic_on_oom" = 0; # Let earlyoom handle OOM natively, but panic if kernel OOM fails
"""

content = content.replace("  zramSwap = {", watchdog_config + "\n  zramSwap = {")
content = content.replace('    "net.ipv4.conf.all.src_valid_mark" = 1;', '    "net.ipv4.conf.all.src_valid_mark" = 1;\n' + sysctls)

with open('modules/common.nix', 'w') as f:
    f.write(content)
