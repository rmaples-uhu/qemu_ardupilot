# QEMU ArduPilot with serial NMEA input

Run **ArduCopter SITL (Copter-4.5.7)** inside an Ubuntu 22.04 amd64 QEMU
guest. This runs the Linux simulation, not firmware for an emulated flight
controller. A physical serial device, PTY, or virtual TCP serial stream feeds
ArduPilot's real NMEA GPS parser:

```text
host serial device / TCP :10110 → QEMU COM2 → guest /dev/ttyS1
    → SITL SERIAL3 (GPS) → NMEA GPS
```

## Prepare and boot

On an Ubuntu/Debian Linux host:

```sh
sudo apt-get update
sudo apt-get install qemu-system-x86 qemu-utils cloud-image-utils curl
./setup.sh
./run.sh
```

Run the scripts as your normal user. Allow about 20 GB of disk space and 4 GB of
guest RAM. KVM is used when accessible; otherwise QEMU uses slower software
emulation. The host needs internet access to download the official Ubuntu cloud
image and its SHA-256 checksums. Alternatively, pass a trusted **Ubuntu 22.04
amd64 qcow2 cloud image** to `./setup.sh /absolute/path/to/image.img`.
The guest needs internet access on its first boot for Ubuntu packages, ArduPilot,
and its submodules.

Cloud-init builds SITL on the first boot (this can take many minutes, especially
without KVM), then starts `ardupilot.service` automatically on every boot.
Wait for `ArduCopter` / `UART connection /dev/ttyS1:9600` on the console before
sending data. There is no interactive guest login or default password.
Build output and service output are printed on the console; provisioning errors
also appear in the guest's `/var/log/cloud-init-output.log`.

The base image, writable disk, seed, flight logs, and saved parameters stay under
`.vm/` (ignored by Git). Setup refuses to overwrite an existing VM. To rebuild
with changed cloud-init settings, stop QEMU and remove `.vm/` first; this deletes
all guest state. Changing the YAML does not reconfigure an existing guest.

## Virtual serial input

By default QEMU listens on **127.0.0.1:10110**, a raw TCP byte stream (not UDP
or Telnet). Choose another port with `./run.sh --tcp 10111`. Only one sender
can connect at a time; it can disconnect and reconnect.

For a quick smoke test, send valid checksummed GGA and RMC sentences once a
second from another host terminal:

```sh
python3 - <<'PY'
import socket
import time

sentences = (
    b"$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n"
    b"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n"
)
with socket.create_connection(("127.0.0.1", 10110)) as stream:
    while True:
        stream.sendall(sentences)
        time.sleep(1)
PY
```

These are static parser-test coordinates and timestamps, not realistic flight
data. For real use send current, consistent GGA/RMC sentences with CRLF endings,
valid checksums and fix status at least once per second. Send each epoch's
GGA/RMC pair together: the parser requires both to be received within 150 ms.

To expose a host PTY for software that requires a serial-device path, install
`socat` and run, after QEMU starts:

```sh
socat -d -d pty,raw,echo=0,link=/tmp/ardupilot-nmea TCP:127.0.0.1:10110
```

Open `/tmp/ardupilot-nmea` in the NMEA-producing application. Remove this symlink
after stopping socat. No MAVLink wrapping is needed for NMEA input.

## Physical serial input

```sh
./run.sh --serial /dev/ttyUSB0
```

The device must be readable/writable by your user (typically through membership
in the host `dialout` group; log out and back in after adding yourself). Do not
run QEMU as root. Stop other applications, including ModemManager if applicable,
from opening the same device. `--serial /dev/pts/N` also accepts an existing PTY.

The guest sets **9600 baud, 8 data bits, no parity, 1 stop bit, no flow control**.
Configure the NMEA source accordingly. For a different baud rate, change both
`SERIAL3_BAUD` (ArduPilot's encoded baud value) and the `:9600` UART argument in
`cloud-init.yaml`, then recreate the VM. For example, 4800 baud uses
`SERIAL3_BAUD 4` and `:4800`; ensure sentence timing still meets the 150 ms window.

## Observe and stop

Connect a host ground station to **TCP 127.0.0.1:5760**; for example, with an
existing MAVProxy installation:

```sh
mavproxy.py --master=tcp:127.0.0.1:5760
```

Use `status GPS_RAW_INT` in MAVProxy to inspect the external coordinates, satellite
count and `fix_type` (3 for the example's 3D fix). With no source attached, GPS
must not report a simulated fix. `GPS_TYPE=5` selects NMEA instead of SITL's
simulated GPS, `GPS_TYPE2=0` disables the second GPS, and `--serial3` replaces
the default simulated GPS transport. `SIM_GPS_TYPE=0` and `SIM_GPS2_TYPE=0` also
disable simulated GPS generation. These parameter names apply to the pinned
4.5.7 release. Saved parameters override defaults, so reset the VM if you change
them through a ground station and want the original configuration back.

Press **Ctrl-a c**, enter `system_powerdown`, and wait for QEMU to exit for a
clean shutdown. **Ctrl-a x** exits immediately and may lose guest writes.
Neither NMEA nor MAVLink is authenticated; both TCP listeners are intentionally
localhost-only. This is a GPS ingestion/simulation environment, not a safe setup
for controlling a real vehicle. External GPS data need not agree with the
simulated vehicle's motion, so EKF/pre-arm warnings can be expected.
