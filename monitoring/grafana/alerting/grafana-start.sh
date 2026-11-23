#!/bin/sh
# Write Supernova's alert provisioning, then start Grafana as its image does.
# The Telegram contact point is written only when a chat is set, so Grafana
# starts (and shows the alerts on its Alerting page) without one.
set -eu
src=/etc/supernova/alerting
dst=/etc/grafana/provisioning/alerting
mkdir -p "$dst"

daily="${SUPERNOVA_ALERT_DAILY_USD:-4}"
if ! printf '%s' "$daily" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
  echo "supernova: SUPERNOVA_ALERT_DAILY_USD='$daily' is not a number like 4 or 4.5; using 4" >&2
  daily=4
fi
sed "s|__DAILY_USD__|$daily|g" "$src/rules.yml" > "$dst/supernova-rules.yml"

chat="${SUPERNOVA_ALERT_TELEGRAM_CHAT:-}"
token="${SUPERNOVA_ALERT_TELEGRAM_TOKEN:-}"
rm -f "$dst/supernova-telegram.yml" "$dst/supernova-telegram-off.yml"

# Grafana keeps a provisioned contact point and policy in its database
# after the file is gone, so turning Telegram off provisions their removal.
telegram_off() {
  echo "supernova: $1; alerts stay in Grafana" >&2
  cp "$src/telegram-off.yml" "$dst/supernova-telegram-off.yml"
}

if [ -z "$chat" ]; then
  telegram_off "SUPERNOVA_ALERT_TELEGRAM_CHAT is not set"
elif ! printf '%s' "$chat" | grep -Eq '^-?[0-9]+$'; then
  telegram_off "SUPERNOVA_ALERT_TELEGRAM_CHAT must be a numeric chat id"
elif ! printf '%s' "$token" | grep -Eq '^[0-9]+:[A-Za-z0-9_-]+$'; then
  telegram_off "no valid bot token for alerts"
else
  sed -e "s|__CHAT__|$chat|g" -e "s|__TOKEN__|$token|g" \
    "$src/telegram.yml" > "$dst/supernova-telegram.yml"
  echo "supernova: alerts go to Telegram chat $chat" >&2
fi

exec /run.sh "$@"
