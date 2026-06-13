# Network Driver Notes

This host uses a Realtek RTL8111/8168/8411 PCIe Gigabit Ethernet controller for
the wired SSH path.

Current observed interface:

- Interface: `enp2s0`
- Driver: `r8168`
- Driver package: `r8168-dkms`
- Link: `1000Mb/s`, full duplex, auto-negotiation on
- EEE before mitigation: enabled, inactive

The goal of the driver-side mitigation is to reduce link instability caused by
NIC and PCIe power-saving transitions. This is separate from Docker/containerd
I/O pressure mitigation.

## Why EEE Is Disabled

EEE means Energy Efficient Ethernet. When enabled, the NIC can advertise low
power idle modes to the link partner. On some Realtek RTL8168-class devices,
EEE state transitions can interact poorly with driver resets, high system load,
or switch behavior.

The observed state was:

```text
EEE status: enabled - inactive
Advertised EEE link modes:  100baseT/Full
                            1000baseT/Full
```

`enabled - inactive` means the link was not currently in low-power idle, but the
feature was enabled and advertised. Disabling it removes this variable from the
link.

Immediate runtime command:

```bash
sudo ethtool --set-eee enp2s0 eee off
```

Verify:

```bash
sudo ethtool --show-eee enp2s0
```

Expected result is `EEE status: disabled` or equivalent output showing that EEE
is no longer advertised.

## NetworkManager Reapply Hook

`ethtool --set-eee` is not guaranteed to survive link reinitialization. It can
be reset when NetworkManager reconnects the device, when the interface is
renegotiated, or after reboot.

To keep EEE disabled after link recovery, install a NetworkManager dispatcher
script:

```text
/etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0
```

The script reapplies EEE off when `enp2s0` comes up:

```sh
#!/bin/sh

IFACE="$1"
STATE="$2"

[ "$IFACE" = "enp2s0" ] || exit 0

case "$STATE" in
  up|dhcp4-change|connectivity-change)
    /usr/sbin/ethtool --set-eee enp2s0 eee off >/dev/null 2>&1 || true
    ;;
esac

exit 0
```

The script must be executable:

```bash
sudo chmod 0755 /etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0
```

## r8168 Module Options

The active driver is the DKMS `r8168` module, not the in-kernel `r8169` driver.
The driver exposes module parameters for EEE and ASPM behavior.

Persistent config:

```text
/etc/modprobe.d/r8168-stability.conf
```

Recommended contents:

```text
options r8168 eee_enable=0 aspm=0 dynamic_aspm=0 s5wol=0
```

Parameter meaning:

- `eee_enable=0`: disable EEE at the driver level.
- `aspm=0`: disable PCIe Active State Power Management for this driver.
- `dynamic_aspm=0`: disable dynamic ASPM switching.
- `s5wol=0`: disable shutdown-state Wake-on-LAN behavior.

These options take effect when the `r8168` module is next loaded. In normal
operation, that means after reboot.

## Apply Script

The repository includes a helper script:

```bash
sudo ./script/apply-host-stability-mitigations.sh
```

For the driver-side mitigation, it performs these actions:

- Installs `/etc/modprobe.d/r8168-stability.conf`.
- Installs `/etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0`.
- Immediately runs `ethtool --set-eee enp2s0 eee off`.
- Prints `ethtool --show-eee enp2s0` output for verification.

The script also contains Docker daemon mitigation. That Docker part only takes
effect after Docker is restarted or the host is rebooted.

## Verification

After applying without reboot:

```bash
sudo ethtool --show-eee enp2s0
cat /etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0
cat /etc/modprobe.d/r8168-stability.conf
```

After reboot:

```bash
lsmod | grep '^r8168'
sudo ethtool --show-eee enp2s0
journalctl -k -b --no-pager | grep -Ei 'r8168|enp2s0|link up|link down|NETDEV|timeout|reset'
```

The desired state is:

- `r8168` is still the loaded driver.
- `EEE` is disabled.
- No repeated `link down`, `NETDEV WATCHDOG`, reset, or timeout messages appear.

## Rollback

Remove the persistent driver options:

```bash
sudo rm /etc/modprobe.d/r8168-stability.conf
```

Remove the NetworkManager dispatcher hook:

```bash
sudo rm /etc/NetworkManager/dispatcher.d/99-disable-eee-enp2s0
```

Optionally re-enable EEE at runtime:

```bash
sudo ethtool --set-eee enp2s0 eee on
```

Reboot to fully reload `r8168` without the module options.

## Escalation Path

If instability continues after disabling EEE and r8168 ASPM:

1. Try a different switch port and Ethernet cable.
2. Test the other physical NIC, if available.
3. Compare `r8168` with the in-kernel `r8169` driver.
4. Consider a global PCIe ASPM test using the kernel parameter `pcie_aspm=off`.

The global `pcie_aspm=off` option is broader than the current mitigation and
should be treated as a second-stage test, not the first change.
