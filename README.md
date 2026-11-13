# Linux System Diagnostics and Monitoring Scripts

A collection of Bash scripts for monitoring and troubleshooting Linux server hardware, storage connectivity and memory-related errors.

The scripts are primarily intended for Linux server environments, including **Proxmox VE**, and provide additional visibility into hardware and kernel-level information that is not always immediately available through standard management interfaces.

## Repository Contents

| Script | Description | Current version |
|---|---|---:|
| [`fc-monitor.sh`](fc-monitor.sh) | Fibre Channel, SCSI, ALUA and Multipath monitoring | 8.9.3 |
| [`dimm-diagnose.sh`](dimm-diagnose.sh) | DIMM memory error diagnostics using DMI and EDAC | 0.6 |
| [`dimm-mapping.conf`](dimm-mapping.conf) | vendor specific Motherboards details for DIMM diagnose| 0.2 |

---

# 1. FC SAN Traffic Monitor – `fc-monitor.sh`

A real-time Fibre Channel monitoring and troubleshooting script for Linux systems.

The script collects information from Linux FC HBA interfaces, SCSI devices, Device Mapper Multipath, ALUA and kernel event logs.

Its main purpose is to provide a consolidated view of the FC storage path, from the server's HBA ports to individual SCSI devices and Multipath logical devices.

It is particularly useful for troubleshooting:
- Intermittent Fibre Channel connectivity.
- SCSI path failures and device state changes.
- Multipath path failures and recovery.
- ALUA path status and prioritization.
- Storage I/O stalls and unusually high I/O latency symptoms.
- FC transport errors and kernel-reported storage problems.

### Features

#### 1.1. FC HBA monitoring

Displays information for detected Fibre Channel host bus adapters:

- FC host identification (`hostX`).
- HBA operational state.
- Configured FC link speed.
- Transmitted traffic (TX).
- Received traffic (RX).

Traffic is calculated from FC port statistics exposed through sysfs.

#### 1.2. FC traffic monitoring

Measures FC data throughput per HBA port:

- TX – traffic transmitted from the server to the SAN.
- RX – traffic received by the server from the SAN.
- Throughput displayed in MB/s and Gbit/s.
- Combined TX/RX summary for all detected FC host ports.

The calculation uses the FC statistics `tx_words` and `rx_words`, with each FC word representing four bytes.

#### 1.3. SCSI device and path monitoring

Displays information for individual SCSI devices associated with FC HBA ports.

Monitored information includes:

- Linux device name (`sda`, `sdb`, etc.).
- Major/minor device numbers.
- SCSI device state.
- ALUA access state.
- Multipath path priority.
- Storage vendor, product and revision information.
- Multipath path checker status.

The script reads the current SCSI state directly from:

`/sys/block/sdX/device/state`

Relevant states include:

- `running`
- `blocked`
- `offline`
- `transport-offline`
- `quiesce`
- Other transitional states.

This is important because a Multipath path may appear active while its corresponding SCSI device is in a problematic state.

#### 1.4. ALUA monitoring

Displays the ALUA access state of individual SCSI paths.

Supported status indicators include:

- `[AO]` – Active/Optimized.
- `[ANO]` – Active/Non-Optimized.
- `[--]` – Other or unavailable access state.

This helps identify optimized and non-optimized paths to storage LUNs.

#### 1.5. Multipath monitoring

Collects information using:

`multipathd show paths format`

Displays:
- Individual SCSI paths.
- Multipath path priority.
- Vendor/Product identification.
- Multipath path checker status.

This makes it possible to compare Multipath information with the actual SCSI device state and ALUA information.

#### 1.6. Per-path I/O statistics

The script monitors I/O activity for each individual SCSI device.

The displayed metrics include:

| Metric | Description |
|---|---|
| IOPS | Completed read and write operations per second. |
| I/O in Progress | Number of I/O requests currently in progress. |
| IO Utilization | Percentage of the measurement interval during which the device had I/O activity, based on `io_ticks`. |

These metrics are useful for identifying potential storage I/O stalls.

For example:

```text
IOPS:             0
I/O in Progress:  20
IO Utilization:   100%
SCSI State:       blocked
```

This combination indicates that I/O requests remain outstanding, while no read or write operations were completed during the measurement interval.

It can be an important indication of an I/O processing or storage path problem. It does not, by itself, identify the underlying hardware component responsible.

#### 1.7. Kernel and Multipath event monitoring

The script monitors two independent journal sources:

- Linux kernel journal (`journalctl -k`).
- Multipath daemon journal (`journalctl -u multipathd`).

Detected events are classified into three categories:

**CRITICAL**
- `DID_TRANSPORT_DISRUPTED`
- `DID_NO_CONNECT`
- `DID_TIME_OUT`
- `I/O error`
- `Buffer I/O error`
- `rejecting I/O to offline device`
- `all paths down`
- `Synchronize Cache failed`

**WARNING**
- `DID_ERROR`
- `aborting command`
- `task abort`
- `resetting device`
- `checker failed`
- `mark as failed`
- `path down`
- FC link-down events
- Command timeouts.

**RECOVERY**
- `Link Up Event`
- `reinstate`
- `reinstated`
- `checker reports path is up`
- Path restored or ready.
- Device recovered or returned to running state.

#### 1.8. Event grouping and duplicate filtering

Related events for the same SCSI device and HBA host are grouped within a configurable 120-second time window.

For example, events such as:

- Path down.
- Multipath path marked as failed.
- FC transport disruption.
- Path reinstatement.
- Path recovery.

can be displayed together as one grouped event rather than as multiple independent messages.

Identical event messages within a grouped incident are filtered.

The script retains the latest 12 grouped events and uses journal cursors for incremental event collection after the initial scan.

#### 1.9. SCSI ALERT

A separate section displays SCSI devices whose current state is not `running`.

Example:

```text
========================================================================
SCSI ALERT: sdd (host1) BLOCKED
========================================================================
```

This section is particularly useful for identifying current SCSI path problems, independently of historical journal events or Multipath checker status.

### Example monitoring output

The main dashboard provides a consolidated view of FC traffic and individual SCSI paths.

```text
HOST     STATE             TX (MB/s / Gbps)       RX (MB/s / Gbps)       LINK
====================================================================================================
host0    [AO]          120.50 MB/s (0.94 Gbps)  250.20 MB/s (1.95 Gbps)  16 Gbps

       Drive  | Maj:min | SCSI state | Path state
              | Prio    | Vendor/Product | MP Health
              | IOPS    | I/O in progress | ALUA | IO-utilization
----------------------------------------------------------------------------------------------------
       sdb    | 8,16    | running    | active/optimized
       sdc    | 8,32    | running    | active/non-optimized
       sdd    | 8,48    | blocked    | active/optimized
```

The output above is an illustrative example, not a live system capture.

### Requirements

- Linux system with Fibre Channel HBA hardware.
- Bash.
- Linux kernel with FC and SCSI sysfs interfaces.
- Device Mapper Multipath.
- `multipathd` service.
- `journalctl` (systemd journal).
- `awk`, `grep`, `readlink`, `date`, `sort` and standard Linux utilities.
- Terminal with `tput` support for display formatting.

Root privileges are recommended to ensure access to all relevant system information and journal entries.

### Installation and usage

Clone the repository:

```bash
git clone https://github.com/hhorvat/scripts.git
cd scripts
```

Make the script executable:

```bash
chmod +x fc-monitor.sh
```

Run:

```bash
sudo ./fc-monitor.sh
```

The default monitoring refresh interval is 5 seconds.

Press `Ctrl+C` to exit.

### Configuration

The main monitoring parameters are defined near the beginning of the script:

```bash
INTERVAL=5
WORD_SIZE=4

EVENT_HISTORY_LIMIT=12
EVENT_SCAN_KERNEL=300
EVENT_SCAN_MULTIPATH=200
EVENT_SEEN_LIMIT=600
EVENT_GROUP_WINDOW=120
```

| Parameter | Description |
|---|---|
| `INTERVAL` | Monitoring refresh interval in seconds. |
| `WORD_SIZE` | FC word size in bytes. |
| `EVENT_HISTORY_LIMIT` | Maximum number of retained event records. |
| `EVENT_SCAN_KERNEL` | Number of kernel journal entries scanned initially. |
| `EVENT_SCAN_MULTIPATH` | Number of Multipath journal entries scanned initially. |
| `EVENT_SEEN_LIMIT` | Maximum number of remembered event identifiers used for duplicate filtering. |
| `EVENT_GROUP_WINDOW` | Time window in seconds for grouping related events. |

### Important notes

- The script monitors individual Linux SCSI paths, not only logical Multipath devices.
- A healthy-looking FC HBA or Multipath status does not necessarily mean that every SCSI path is healthy.
- `IO Utilization` represents I/O active time, not maximum device performance or bandwidth utilization.
- IOPS values are calculated from completed read and write operations between monitoring intervals.
- Historical journal events are not necessarily indications of current failures. The separate SCSI ALERT section reports current non-running SCSI device states.
- Event classification is based on matching kernel and Multipath log messages. It is a diagnostic aid, not a complete root-cause analysis.
- The script does not replace vendor-specific SAN diagnostics, FC switch monitoring or storage array management tools.

---

# 2. DIMM Diagnose – `dimm-diagnose.sh`

A Linux memory diagnostic script designed to identify potential faulty DIMM modules using hardware inventory information and EDAC error counters.

The script combines two information sources:

- **DMI/SMBIOS** – memory module inventory, including DIMM location, capacity and part number.
- **EDAC (Error Detection And Correction)** – memory error counters reported by the Linux kernel.

Its main purpose is to help identify which memory module or memory channel is reporting errors and, where supported, map the logical EDAC location to a physical DIMM slot.

The current physical slot mapping is implemented for the **HPE ProLiant BL460c Gen8** platform.

### Features

#### 2.1. System identification

Uses `dmidecode` to identify:

- System manufacturer.
- System product name.
- Hardware platform.

The script detects the HPE ProLiant BL460c Gen8 platform and enables its specific physical DIMM slot mapping.

#### 2.2. Installed DIMM inventory

Reads SMBIOS Type 17 information using:

```bash
dmidecode -t 17
```

Displays detected memory modules, including:

- Processor identifier.
- DIMM slot number.
- Installed memory capacity.
- Memory module part number, when available.

This information provides the installed memory configuration against which EDAC error reports can be compared.

#### 2.3. EDAC memory error monitoring

Reads memory error counters from:

```text
/sys/devices/system/edac/mc/
```

For each detected EDAC DIMM, the script collects:

| Counter | Description |
|---|---|
| Corrected Errors (CE) | Memory errors detected and corrected by the hardware. |
| Uncorrected Errors (UE) | Memory errors that could not be corrected by the hardware. |

The script identifies DIMMs with non-zero error counters and displays their EDAC labels, socket, processor, memory channel and DIMM index.

#### 2.4. Physical DIMM slot mapping – HPE ProLiant BL460c Gen8

For the HPE ProLiant BL460c Gen8, the script translates EDAC logical DIMM information into physical memory slot identification.

The mapping considers:

- Processor/socket.
- Memory channel.
- EDAC DIMM index.
- Physical DIMM slot.
- HPE physical slot designation.

The physical slot labels include:

- P1-A through P1-H.
- P2-A through P2-H, where applicable.

The mapping is platform-specific and should not be assumed to apply to other server models.

#### 2.5. Potential faulty DIMM identification

When non-zero EDAC error counters are detected, the script reports the corresponding logical DIMM.

For supported HPE BL460c Gen8 systems, it also attempts to identify the physical DIMM slot.

The report includes:

- EDAC label.
- Socket and processor.
- Memory channel.
- DIMM index.
- Corrected error count.
- Uncorrected error count.
- Physical DIMM slot, when successfully mapped.
- DMI inventory confirmation.
- DIMM capacity and part number, when available.
- Error severity indication.

#### 2.6. Final diagnosis

The script provides a summary indicating whether potential DIMM candidates were detected.

It also lists possible causes of reported memory errors:

1. Faulty DIMM module.
2. DIMM slot or contact problem.
3. CPU memory controller.
4. CPU socket.
5. Motherboard.

**Important:** EDAC error counters identify the logical memory location reporting errors. They do not prove that the physical DIMM itself is defective. Further hardware diagnostics may be required.

### Requirements

- Linux system with EDAC support.
- Bash.
- `dmidecode`.
- Root privileges.
- Kernel EDAC sysfs interfaces available under `/sys/devices/system/edac/mc/`.

The platform-specific physical DIMM mapping currently supports HPE ProLiant BL460c Gen8.

On other platforms, the script can display generic EDAC information, but physical DIMM slot mapping is not configured.

### Installation and usage

Clone the repository:

```bash
git clone https://github.com/hhorvat/scripts.git
cd scripts
```

Make the script executable:

```bash
chmod +x dimm-diagnose.sh
```

Run as root:

```bash
sudo ./dimm-diagnose.sh
```

### Example output

```text
================================================
                 DIMM DIAGNOSTICS
================================================
Manufacturer : HP
Model        : ProLiant BL460c Gen8

------------------------------------------------
INSTALLED DIMM MODULES
------------------------------------------------
PROC 1 DIMM 1 - 16384 MB
  Part Number: XXXXX-XXX

------------------------------------------------
EDAC DIMM COUNTERS
------------------------------------------------

Label: SrcID#0_Chan#1_DIMM#0
Corrected errors: 15
Uncorrected errors: 0

================================================
              POTENTIAL FAULTY DIMMs
================================================

EDAC LABEL: SrcID#0_Chan#1_DIMM#0
Socket: 0
Processor: PROC 1
Channel: 1
DIMM index: 0
Corrected errors: 15
Uncorrected errors: 0

POTENTIAL DIMM:
PROC 1 DIMM 1 (P1-A)

DMI status: INSTALLED
DIMM size: 16384 MB

SEVERITY: CORRECTED ERRORS
```

The example is illustrative. Actual EDAC labels, DIMM locations and output depend on the server platform and kernel EDAC driver.

### Important notes

- EDAC counters are provided by the kernel and depend on platform firmware, memory controller and EDAC driver support.
- Some server platforms do not expose detailed DIMM-level counters.
- Corrected errors do not necessarily mean that a DIMM has failed.
- Uncorrected errors indicate a more serious memory problem and should be investigated promptly.
- Physical slot mapping must be verified against the server's hardware documentation.
- The script is a diagnostic aid and does not replace vendor hardware diagnostics.

---

# 3. Supported environments

The scripts have different hardware requirements and platform dependencies.

| Environment / Platform | `fc-monitor.sh` | `dimm-diagnose.sh` |
|---|---|---|
| Proxmox VE 9.x | FC/SCSI monitoring target | Tested on Proxmox VE 9.1.x and 9.2.x |
| Linux with Fibre Channel HBA | Yes, with required FC interfaces | Not required |
| Linux with Device Mapper Multipath | Required for Multipath monitoring | Not required |
| HPE ProLiant BL460c Gen8 | FC monitoring, depending on installed hardware | Platform-specific DIMM mapping |
| Other Linux servers | Supported where required interfaces are available | Generic EDAC analysis, if EDAC is exposed |

Actual functionality depends on kernel configuration, installed drivers, hardware and available sysfs interfaces.

# 4. License

Both scripts are released under the **Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)** license.

You are free to:

- Share and redistribute the scripts.
- Adapt and modify the source code.
- Use them for personal, educational and commercial purposes.

Under the license terms, appropriate attribution must be provided and derivative works must be distributed under the same license.

License details:

https://creativecommons.org/licenses/by-sa/4.0/

# 5. Author

**Hrvoje Horvat**

GitHub: https://github.com/hhorvat

Repository:

https://github.com/hhorvat/scripts

# 6. Feedback and contributions

Feedback, bug reports, feature requests and testing results are welcome.

Suggestions for additional hardware platforms, EDAC mappings, FC HBA support and storage troubleshooting features are especially appreciated.

Please include the following information when reporting an issue:

- Linux distribution and version.
- Kernel version.
- Hardware model.
- FC HBA model and driver, where applicable.
- Script version.
- Relevant command output and system logs.

Contributions that improve hardware compatibility, diagnostic accuracy and usability are welcome.
