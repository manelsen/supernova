#!/bin/sh
# Write Supernova's alert provisioning, then start Grafana as its image does.
# The Telegram contact point is written only when a chat is set, so Grafana
# starts (and shows the alerts on its Alerting page) without one.
set -eu
src=/etc/supernova/alerting
dst=/etc/grafana/provisioning/alerting
mkdir -p "$dst"

daily="${SUPERNOVA_ALERT_DAILY_USD:-4}"
case "$daily" in
  ''|*[!0-9.]*) echo "supernova: SUPERNOVA_ALERT_DAILY_USD='$daily' is not a number; using 4" >&2; daily=4 ;;
esac
sed "s|__DAILY_USD__|$daily|g" "$src/rules.yml" > "$dst/supernova-rules.yml"

chat="${SUPERNOVA_ALERT_TELEGRAM_CHAT:-}"
token="${SUPERNOVA_ALERT_TELEGRAM_TOKEN:-}"
rm -f "$dst/supernova-telegram.yml"
if [ -z "$chat" ]; then
  echo "supernova: alerts show only in Grafana; set SUPERNOVA_ALERT_TELEGRAM_CHAT to get them on Telegram" >&2
elif ! printf '%s' "$chat" | grep -Eq '^-?[0-9]+$'; then
  echo "supernova: SUPERNOVA_ALERT_TELEGRAM_CHAT must be a numeric chat id; alerts stay in Grafana" >&2
elif ! printf '%s' "$token" | grep -Eq '^[0-9]+:[A-Za-z0-9_-]+$'; then
  echo "supernova: no valid bot token for alerts; alerts stay in Grafana" >&2
else
  sed -e "s|__CHAT__|$chat|g" -e "s|__TOKEN__|$token|g" \
    "$src/telegram.yml" > "$dst/supernova-telegram.yml"
  echo "supernova: alerts go to Telegram chat $chat" >&2
fi

exec /run.sh "$@"
