# Linux System Diagnostics and Monitoring Scripts

A collection of Bash-based tools for monitoring and troubleshooting
Linux server hardware, Fibre Channel storage connectivity, SCSI paths,
Multipath, and memory-related errors.

The scripts are primarily intended for Linux server environments,
including **Proxmox VE**. They expose selected hardware and kernel-level
information that may not be immediately visible through standard
management interfaces.

The tools are diagnostic aids. They help identify symptoms and correlate
information from Linux sysfs, kernel interfaces, systemd journal,
DMI/SMBIOS, and EDAC. They do not replace vendor hardware diagnostics,
SAN switch monitoring, or storage-array management tools.

## Repository contents

| File                                     | Description                                                            | Version / status |
|:-----------------------------------------|:-----------------------------------------------------------------------|-----------------:|
| [`fc-monitor.sh`](fc-monitor.sh)         | Fibre Channel, SCSI, ALUA, Multipath and I/O monitoring                |            8.9.5 |
| [`dimm-diagnose.sh`](dimm-diagnose.sh)   | DIMM inventory and EDAC memory-error diagnostics                       |              0.8 |
| [`dimm-mapping.conf`](dimm-mapping.conf) | Platform profiles and DIMM mapping metadata used by `dimm-diagnose.sh` |  See file header |

The scripts and configuration file are released under **Creative Commons
Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)**.


## 1. FC SAN Traffic Monitor – `fc-monitor.sh`

A real-time Fibre Channel monitoring and troubleshooting script for
Linux systems.

The script collects information from FC HBA interfaces, SCSI devices,
Device Mapper Multipath, ALUA sysfs attributes, block-device I/O
statistics, and kernel and multipathd journal entries.

Its purpose is to provide a consolidated view of the server-side FC
storage paths, from FC HBA ports to individual SCSI devices. It is
particularly useful when investigating:

- Intermittent Fibre Channel connectivity.
- SCSI path failures and device-state changes.
- Multipath path failures and recovery.
- ALUA optimized and non-optimized paths.
- Storage I/O stalls and outstanding requests.
- FC transport errors and kernel-reported storage problems.

### 1.1. FC HBA traffic monitoring

The script detects FC hosts exposed under:

``` text
/sys/class/fc_host/
```

For each detected FC host, it displays:

- FC host identifier (`hostX`).
- A summary state derived from the ALUA state of its associated SCSI
  paths.
- Transmitted traffic (TX).
- Received traffic (RX).
- Configured FC link speed.

**Important:** The displayed `[AO]`, `[ANO]`, or `[--]` value is an ALUA
summary derived from the associated SCSI paths. It is not a direct FC
HBA link-operational-state indicator.

Traffic is calculated from the FC port statistics:

``` text
/sys/class/fc_host/hostX/statistics/tx_words
/sys/class/fc_host/hostX/statistics/rx_words
```

The calculation uses four bytes per FC word. Throughput is displayed
using decimal units:

- MB/s: 1 MB = 1,000,000 bytes.
- Gbit/s: 1 Gbit/s = 1,000,000,000 bits per second.

The dashboard also displays combined TX and RX throughput for the
detected FC host ports.

### 1.2. SCSI device and path monitoring

The script displays individual SCSI devices associated with detected FC
hosts.

For each path, it can display:

- Linux device name (`sda`, `sdb`, etc.).
- Major/minor device numbers.
- Current SCSI device state.
- ALUA access state.
- Multipath path priority.
- SCSI vendor, product and revision identification.
- Multipath path-checker status.

The current SCSI state is read from:

``` text
/sys/block/sdX/device/state
```

Examples of Linux SCSI device states include:

- `running`
- `blocked`
- `offline`
- `transport-offline`
- `quiesce`

The actual states available depend on the kernel and device/driver
behavior.

A Multipath path state and its corresponding SCSI device state are
separate pieces of information. Comparing them can help identify
inconsistencies or path problems that may not be obvious from a single
status field.

### 1.3. ALUA monitoring

The script reads the ALUA access state exposed for each SCSI path, when
available.

The dashboard uses these indicators:

| Indicator | Meaning                                          |
|:----------|:-------------------------------------------------|
| `[AO]`    | Active/Optimized                                 |
| `[ANO]`   | Active/Non-Optimized                             |
| `[--]`    | Other, unavailable, or unrecognized access state |

The host-level indicator is a summary of its associated paths:

- `[AO]` is shown when at least one running path reports
  `active/optimized`.
- `[ANO]` is shown when no optimized path is found but at least one
  running path reports `active/non-optimized`.
- `[--]` is shown when neither condition is confirmed.

This is a monitoring summary, not a complete assessment of the storage
array’s ALUA configuration.

### 1.4. Device Mapper Multipath monitoring

Multipath information is collected through `multipathd`, using:

``` bash
multipathd show paths raw format
```

The script uses the following information:

- `%d` – SCSI device name.
- `%p` – path priority.
- `%s` – vendor/product/revision identification.
- `%T` – path-checker state.

The compact dashboard uses the `MP` column for the path-checker result,
for example `ready`. This is distinct from the ALUA access state and
from the SCSI device state.

The exact checker values depend on the configured path checker and the
installed Device Mapper Multipath version.

### 1.5. Per-path I/O statistics

The script reads Linux block-device statistics from:

``` text
/sys/block/sdX/stat
```

It displays the following per-path metrics:

| Metric  | Description                                                                                           |
|:--------|:------------------------------------------------------------------------------------------------------|
| IOPS    | Completed read and write operations per second, calculated over the measured interval.                |
| I/O     | Number of I/O requests currently in progress.                                                         |
| IO-util | Percentage of the measured interval represented by block-device I/O active time, based on `io_ticks`. |

The script uses the actual elapsed sampling time when calculating
throughput, IOPS, and I/O utilization. The configured refresh interval
is therefore not necessarily identical to the measured interval, because
processing and journal collection also take time.

I/O utilization is capped at 100% in the displayed result.

These metrics can help identify unusual I/O behavior. For example,
outstanding requests combined with no completed I/O and a non-running
SCSI state can indicate a storage-path or I/O-processing problem. These
values do not, by themselves, identify the failing hardware component.

### 1.6. Kernel and Multipath event monitoring

The script independently monitors two systemd journal sources:

- Linux kernel: `journalctl -k`
- Multipath daemon: `journalctl -u multipathd`

The initial scan reads a bounded number of recent entries. Subsequent
scans use journal cursors to collect new entries.

Matching messages are classified into three diagnostic categories.

**CRITICAL**

Examples include:

- `DID_TRANSPORT_DISRUPTED`
- `DID_NO_CONNECT`
- `DID_TIME_OUT`
- `I/O error`
- `Buffer I/O error`
- `rejecting I/O to offline device`
- `all paths down`
- `Synchronize Cache failed`

**WARNING**

Examples include:

- `DID_ERROR`
- `FAILED Result:`
- `aborting command`
- `task abort`
- `resetting device`
- `checker failed`
- `mark as failed`
- `path down`
- FC link-down events
- Command and I/O timeouts

**RECOVERY**

Examples include:

- `Link Up Event`
- `reinstate` or `reinstated`
- `checker reports path is up`
- Path restored or ready
- Device recovered or returned to running state

Classification is based on matching log-message text. It is a diagnostic
aid, not a complete interpretation of every possible kernel or Multipath
event.

### 1.7. Event grouping and duplicate filtering

Related events for the same SCSI device and host can be grouped when
they occur within the configured time window.

The script filters identical event messages within a grouped incident
and retains a bounded in-memory event history.

The default settings are:

- Event history limit: 12 records.
- Initial kernel journal scan: 300 entries.
- Initial Multipath journal scan: 200 entries.
- Remembered event identifiers: 600.
- Event grouping window: 120 seconds.

The displayed history is not a persistent event database. It is
maintained in memory while the script is running. Journal cursors are
used for incremental collection during that run.

Events without a resolved SCSI device remain independent global events.

### 1.8. SCSI ALERT

The `SCSI ALERT` section reports FC-attached SCSI devices whose current
state is not `running`.

Example:

``` text
========================================================================
SCSI ALERT: sdd (host1) BLOCKED
========================================================================
```

The check is limited to SCSI devices whose sysfs device path resolves to
a host exposed through `/sys/class/fc_host/`. Local SATA/SAS devices
that are not attached to an FC host are not included in this alert.

This section reports current device state independently of the
historical journal event list and Multipath path-checker result.

### 1.9. Example monitoring output

The following is an illustrative example based on the compact dashboard
layout used by the script. Values are examples, not live measurements.

``` text
FC SAN Traffic Monitor v8.9.5 | Refresh: 2026-11-13 13:02:26 | Interval: 5s
====================================================================================================
HOST     STATE              TX (MB/s / Gbps)           RX (MB/s / Gbps)       LINK
====================================================================================================
host1    [AO]           0.05 MB/s (  0.00 Gbps) |       0.00 MB/s (  0.00 Gbps)   8 Gbps
       ---------------------------------------------------------------------------------------------------
       Drive | Maj:min | SCSI    | Path                | Prio | Vendor/Prod.     | MP       | IOPS  | I/O | ALUA  | IO-util
       ---------------------------------------------------------------------------------------------------
       sdb   | 8,16    | running | active/optimized    | 50   | 3PARdata,VV,3315 | ready    | 1.0   | 0   | [AO]  | 0.4%
       sdc   | 8,32    | running | active/optimized    | 50   | 3PARdata,VV,3315 | ready    | 1.0   | 0   | [AO]  | 1.7%
====================================================================================================
Summary: TX 0.05 MB/s | RX 0.00 MB/s
====================================================================================================
```

### 1.10. Requirements

- Linux system with Fibre Channel HBA hardware.
- Bash with support for associative arrays.
- Linux kernel exposing FC and SCSI sysfs interfaces.
- Device Mapper Multipath and the `multipathd` service for Multipath
  information.
- systemd journal and `journalctl`.
- Standard utilities used by the script, including `awk`, `grep`,
  `readlink`, `date`, `sort`, `tput`, and `clear`.

Root privileges are recommended so the script can read the required
system information and journal entries.

### 1.11. Installation and usage

Clone the repository:

``` bash
git clone https://github.com/hhorvat/scripts.git
cd scripts
```

Make the script executable:

``` bash
chmod +x fc-monitor.sh
```

Run it as root:

``` bash
sudo ./fc-monitor.sh
```

The default refresh interval is five seconds. Press `Ctrl+C` to exit.

### 1.12. Configuration

The main parameters are defined near the beginning of the script:

``` bash
INTERVAL=5
WORD_SIZE=4

EVENT_HISTORY_LIMIT=12
EVENT_SCAN_KERNEL=300
EVENT_SCAN_MULTIPATH=200
EVENT_SEEN_LIMIT=600
EVENT_GROUP_WINDOW=120
```

| Parameter              | Description                                                           |
|:-----------------------|:----------------------------------------------------------------------|
| `INTERVAL`             | Sleep interval between monitoring cycles, in seconds.                 |
| `WORD_SIZE`            | FC word size in bytes, used for throughput calculations.              |
| `EVENT_HISTORY_LIMIT`  | Maximum number of retained in-memory event records.                   |
| `EVENT_SCAN_KERNEL`    | Number of kernel journal entries read during the initial scan.        |
| `EVENT_SCAN_MULTIPATH` | Number of Multipath journal entries read during the initial scan.     |
| `EVENT_SEEN_LIMIT`     | Maximum number of event identifiers retained for duplicate filtering. |
| `EVENT_GROUP_WINDOW`   | Time window, in seconds, for grouping related events.                 |

### 1.13. Important notes and limitations

- The script monitors individual Linux SCSI paths associated with FC
  hosts; it does not replace logical Multipath device monitoring.
- The host-level `[AO]`/`[ANO]`/`[--]` value is an ALUA summary, not a
  direct FC link-state indicator.
- `IO-util` represents block-device I/O active time. It is not a measure
  of maximum device performance, bandwidth utilization, or latency.
- IOPS is calculated from completed read and write operations between
  samples.
- Historical journal events are not necessarily current faults. The
  separate `SCSI ALERT` section reports current non-running FC-attached
  SCSI devices.
- Event classification is based on message matching and may not
  recognize every vendor- or driver-specific message.
- The script does not identify the root cause of every storage problem.
- It does not replace FC switch monitoring, storage-array diagnostics,
  or vendor-specific tools.


## 2. DIMM Diagnose – `dimm-diagnose.sh`

A Linux memory diagnostic script that combines DMI/SMBIOS inventory
information with Linux EDAC memory-error counters.

Its purpose is to help identify logical memory locations reporting
errors and, where a platform-specific mapping has been verified,
correlate those locations with physical DIMM slots.

The script uses:

- **DMI/SMBIOS** – system and memory-module inventory, including slot
  locator, capacity, and part number when provided by firmware.
- **EDAC** – memory-controller error information and counters exposed by
  the Linux kernel.
- **`dimm-mapping.conf`** – platform profiles and mapping metadata.

EDAC counters identify the logical location reported by the kernel. They
do not automatically prove that a physical DIMM is defective.

### 2.1. System identification

The script uses `dmidecode` to identify the system manufacturer and
product model.

It compares the detected system information with platform profiles in
`dimm-mapping.conf`.

Recognized profiles include:

- HPE ProLiant BL460c Gen8.
- HPE ProLiant BL460c Gen9.
- HPE ProLiant DL380 Gen10.
- Dell PowerEdge R630.
- Dell PowerEdge R740.
- Dell PowerEdge R750.
- Lenovo ThinkSystem SR650 (first generation).

A recognized profile does not necessarily mean that physical DIMM
mapping is supported. The mapping status must be considered separately.

### 2.2. Installed DIMM inventory

The script reads SMBIOS Type 17 information using:

``` bash
dmidecode -t 17
```

Depending on the information supplied by system firmware, the inventory
can include:

- Memory-device locator.
- Installed memory capacity.
- Memory-module part number.
- Other available DIMM attributes.

SMBIOS data is firmware-provided. Locator strings and other fields can
differ between server models and firmware versions.

### 2.3. EDAC memory error monitoring

The script reads EDAC information from:

``` text
/sys/devices/system/edac/mc/
```

It collects available memory-controller and DIMM information, including
corrected and uncorrected error counters.

| Counter                 | Meaning                                         |
|:------------------------|:------------------------------------------------|
| CE – Corrected Errors   | Errors detected and corrected by the hardware.  |
| UE – Uncorrected Errors | Errors reported as uncorrected by the hardware. |

The exact EDAC attributes and labels depend on the kernel, EDAC driver,
memory controller, and platform.

The script reports available logical information such as EDAC label,
socket, channel, DIMM index, and error counters.

### 2.4. Physical DIMM mapping and mapping status

The configuration database distinguishes between a physical memory
layout and a verified EDAC-to-physical-slot translation.

These concepts must not be treated as interchangeable.

| Mapping status   | Meaning                                                                                                                   |
|:-----------------|:--------------------------------------------------------------------------------------------------------------------------|
| `VERIFIED`       | The platform-specific EDAC-to-slot translation is implemented and has been validated for the documented configuration.    |
| `REFERENCE_ONLY` | Platform layout or EDAC/SMBIOS correlation information is available, but physical slot translation has not been verified. |
| `UNSUPPORTED`    | No supported platform mapping is available; report logical EDAC information only.                                         |

### HPE ProLiant BL460c Gen8

The current script includes a platform-specific EDAC channel/DIMM-index
translation for the HPE ProLiant BL460c Gen8.

The configuration identifies this profile as `VERIFIED`. The mapping is
specific to the documented implementation and should still be checked
against the target system, firmware, and EDAC driver.

### HPE ProLiant BL460c Gen9

The Gen9 profile is `REFERENCE_ONLY`.

The script can correlate logical EDAC information with SMBIOS inventory,
but the physical EDAC-to-slot translation has not been verified. It must
not infer a physical DIMM slot from an unverified channel/index
relationship.

### Other platform profiles

The configuration also contains reference profiles for selected HPE,
Dell, and Lenovo systems. These profiles describe platform layouts, but
they do not provide verified physical EDAC translations.

A profile being present in the configuration file is not proof that
automatic physical-slot identification is supported.

### 2.5. Potential DIMM error identification

When non-zero EDAC error counters are detected, the script reports the
corresponding logical memory location and available inventory
correlation.

Depending on the platform and mapping status, the report may include:

- EDAC label.
- Socket or processor identification.
- Memory channel.
- DIMM index.
- Corrected error count.
- Uncorrected error count.
- SMBIOS inventory match.
- DIMM capacity and part number, when available.
- Physical slot identification, only when supported by a verified
  mapping.

The script’s result should be treated as a diagnostic candidate, not a
definitive hardware-failure verdict.

### 2.6. Possible causes of memory errors

Reported EDAC errors can be associated with several possible causes:

1.  Faulty DIMM module.
2.  DIMM slot or contact problem.
3.  CPU integrated memory controller.
4.  CPU socket or processor connection.
5.  Motherboard or memory-channel circuitry.

Further testing and vendor hardware diagnostics may be needed to
identify the actual cause.

### 2.7. Requirements

- Linux system with EDAC support exposed by the kernel.
- Bash.
- `dmidecode`.
- Root privileges.
- Readable EDAC sysfs interfaces under `/sys/devices/system/edac/mc/`.
- `dimm-mapping.conf` located in the same directory as
  `dimm-diagnose.sh`.

The script checks for root privileges, `dmidecode`, and the
configuration file before proceeding.

The availability and detail of EDAC information depend on platform
firmware, kernel configuration, and the applicable EDAC driver.

### 2.8. Installation and usage

Clone the repository:

``` bash
git clone https://github.com/hhorvat/scripts.git
cd scripts
```

Keep both required DIMM files in the same directory:

``` text
dimm-diagnose.sh
dimm-mapping.conf
```

Make the script executable:

``` bash
chmod +x dimm-diagnose.sh
```

Run it as root:

``` bash
sudo ./dimm-diagnose.sh
```

### 2.9. Configuration database

The file `dimm-mapping.conf` is an INI-like data file. It is parsed by
the script and is **not sourced or executed as Bash code**.

It contains platform sections with fields such as:

- Manufacturer and product matching expressions.
- Mapping status.
- Mapping scope.
- CPU socket and memory-channel layout information.
- Physical slot naming scheme.
- EDAC mapping entries, where a verified translation exists.

Do not add an EDAC translation merely because a physical layout is
documented. A translation must be validated against the exact server
model, system board, processor, firmware, and EDAC driver.

The configuration file contains comments describing its format and the
limitations of individual profiles.

### 2.10. Important notes and limitations

- EDAC counters are provided by the Linux kernel and depend on platform
  firmware, memory controller, and EDAC driver support.
- Some systems expose controller-level errors but not detailed
  DIMM-level counters.
- Corrected errors do not necessarily mean that a DIMM has failed.
- Uncorrected errors indicate a more serious memory problem and should
  be investigated promptly.
- SMBIOS inventory is firmware-provided and may be incomplete or
  inconsistent.
- A `REFERENCE_ONLY` profile must not be used to claim a verified
  physical DIMM location.
- Physical slot mapping must be validated against the server
  documentation and actual hardware.
- The script is a diagnostic aid and does not replace vendor hardware
  diagnostics.


## 3. Supported environments and platform coverage

The scripts have different hardware and kernel-interface requirements.

| Environment / platform                      | `fc-monitor.sh`                                                    | `dimm-diagnose.sh`                                                   |
|:--------------------------------------------|:-------------------------------------------------------------------|:---------------------------------------------------------------------|
| Proxmox VE 9.x                              | Intended target where FC and Multipath interfaces are available    | Linux EDAC/DMI support required; platform mapping depends on profile |
| Linux with Fibre Channel HBA                | FC monitoring supported when required sysfs interfaces are exposed | Not required                                                         |
| Linux with Device Mapper Multipath          | Required for Multipath path information                            | Not required                                                         |
| HPE ProLiant BL460c Gen8                    | FC monitoring, depending on installed FC hardware                  | Verified platform-specific EDAC mapping                              |
| HPE ProLiant BL460c Gen9                    | FC monitoring, depending on installed FC hardware                  | EDAC/SMBIOS correlation only; physical mapping not verified          |
| HPE ProLiant DL380 Gen10                    | FC monitoring, depending on installed FC hardware                  | Reference profile only                                               |
| Dell PowerEdge R630/R740/R750               | FC monitoring, depending on installed FC hardware                  | Reference profiles only                                              |
| Lenovo ThinkSystem SR650 (first generation) | FC monitoring, depending on installed FC hardware                  | Reference profile only                                               |
| Other Linux servers                         | Supported where required FC/SCSI interfaces are available          | Generic EDAC reporting where supported; no assumed physical mapping  |

The presence of a platform profile does not imply that every feature has
been tested or that physical DIMM mapping is verified.

Actual functionality depends on hardware, firmware, kernel
configuration, drivers, and available sysfs interfaces.


## 4. License

The scripts and associated configuration file are released under the
**Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA
4.0)** license.

You are free to:

- Share and redistribute the material.
- Adapt and modify the material.
- Use it for personal, educational, and commercial purposes.

Under the license terms, appropriate attribution must be provided and
derivative works must be distributed under the same license.

License details:

[Creative Commons BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)


## 5. Author

**Hrvoje Horvat**

GitHub: [hhorvat](https://github.com/hhorvat)

Repository: [hhorvat/scripts](https://github.com/hhorvat/scripts)


## 6. Feedback and contributions

Feedback, bug reports, feature requests, and testing results are
welcome.

Suggestions for additional hardware platforms, EDAC mappings, FC HBA
support, and storage troubleshooting features are especially
appreciated.

When reporting an issue, please include:

- Linux distribution and version.
- Kernel version.
- Hardware model.
- Script version.
- FC HBA model and driver, where applicable.
- Relevant command output and system logs.

For DIMM mapping reports, also include the available DMI/SMBIOS and EDAC
information. Do not publish serial numbers, asset identifiers, WWNs, or
other sensitive infrastructure details unless they have been
appropriately redacted.

Contributions that improve hardware compatibility, diagnostic accuracy,
and usability are welcome.
