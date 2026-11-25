#!/usr/bin/env python3
"""Grava, contra o gateway real do Discord, os eventos que os testes servem.

Roda à mão, num servidor de teste, quando o formato do Discord mudar (PRD-D,
D1). Precisa de um bot com a Message Content Intent ligada no Developer
Portal e convidado ao servidor de teste:

    python3 -I dev/discord/gravar.py --env /caminho/.env --segundos 180

Enquanto grava, faça no servidor e no privado do bot o que os testes cobrem:
uma mensagem com aspas e quebra de linha, uma imagem, uma mensagem de voz,
uma figurinha, um clique num botão (o script manda uma mensagem com um botão
se receber --canal) e, se quiser, um comando / já registrado.

O que sai é anonimizado antes de gravar: ids trocados por números fixos
(o mesmo id vira sempre o mesmo número), nomes e textos por marcadores,
tokens de interação e sessão por marcadores, URLs de anexo sem a assinatura.
Os arquivos vão para test/fixtures/discord/gravadas/, para revisão antes de
substituir os de fevereiro. Só a biblioteca padrão; o token nunca é impresso.
"""

import argparse
import base64
import json
import os
import re
import socket
import ssl
import struct
import time
import urllib.request

API = "https://discord.com/api/v10"
# Guilds | GuildMessages | DirectMessages | MessageContent (37377)
INTENTS = 1 | 512 | 4096 | 32768
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "test", "fixtures",
                   "discord", "gravadas")


def load_token(path):
    for line in open(path, encoding="utf-8"):
        if line.startswith("SUPERNOVA_DISCORD_TOKEN="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("SUPERNOVA_DISCORD_TOKEN não está em " + path)


def rest(token, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bot " + token)
    req.add_header("User-Agent", "DiscordBot (https://supernova.bot, 0.4)")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b"null")


# -- WebSocket mínimo (cliente, quadros de texto) -----------------------------

def ws_connect(url):
    host = url.split("//", 1)[1].split("/", 1)[0]
    path = "/" + url.split("//", 1)[1].split("/", 1)[1] if "/" in url.split("//", 1)[1] else "/"
    raw = socket.create_connection((host, 443), timeout=30)
    sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += sock.recv(1)
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        raise SystemExit("o gateway recusou a conexão")
    return sock


def ws_send(sock, text):
    payload = text.encode()
    mask = os.urandom(4)
    size = len(payload)
    if size < 126:
        header = struct.pack("!BB", 0x81, 0x80 | size)
    elif size < 65536:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, size)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, size)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("conexão fechada")
        data += chunk
    return data


def ws_recv(sock):
    """Um texto completo, ou None num quadro de fechamento."""
    message = b""
    while True:
        first, second = recv_exact(sock, 2)
        opcode, size = first & 0x0F, second & 0x7F
        if size == 126:
            size = struct.unpack("!H", recv_exact(sock, 2))[0]
        elif size == 127:
            size = struct.unpack("!Q", recv_exact(sock, 8))[0]
        payload = recv_exact(sock, size)
        if opcode == 8:
            code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
            print(f"o gateway fechou a conexão (código {code})")
            return None
        message += payload
        if first & 0x80:
            return message.decode()


# -- Anonimização --------------------------------------------------------------

SNOWFLAKE = re.compile(r"^\d{15,21}$")
NAMES = {"username", "global_name", "nick", "name", "display_name"}
TEXTS = {"content", "description", "title", "topic", "filename", "value"}
SECRETS = {"token", "session_id", "avatar", "banner", "icon", "splash",
           "email", "discovery_splash", "avatar_decoration_data", "hash"}


class Anon:
    def __init__(self):
        self.ids, self.counts = {}, {}

    def snowflake(self, value):
        if value not in self.ids:
            self.ids[value] = str(900000000000000000 + len(self.ids) + 1)
        return self.ids[value]

    def marker(self, kind):
        self.counts[kind] = self.counts.get(kind, 0) + 1
        return f"{kind}_{self.counts[kind]}"

    def url(self, value):
        value = value.split("?", 1)[0]  # sem a assinatura do CDN
        return re.sub(r"\d{15,21}", lambda m: self.snowflake(m.group(0)), value)

    def walk(self, value, key=None):
        if isinstance(value, dict):
            return {k: self.walk(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [self.walk(v, key) for v in value]
        if not isinstance(value, str):
            return value
        if key in SECRETS:
            return None if key != "token" and key != "session_id" else self.marker(key)
        if SNOWFLAKE.match(value):
            return self.snowflake(value)
        if key in ("url", "proxy_url", "resume_gateway_url"):
            return self.url(value)
        if key in NAMES:
            return self.marker("username" if key != "name" else "name")
        if key in TEXTS:
            return self.marker(key)
        return value


# -- Gravação ------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True)
    parser.add_argument("--segundos", type=int, default=180)
    parser.add_argument("--canal", help="canal de teste para mandar um botão")
    args = parser.parse_args()
    token = load_token(args.env)

    if args.canal:
        rest(token, "POST", f"/channels/{args.canal}/messages", {
            "content": "Botão de teste da gravação",
            "allowed_mentions": {"parse": []},
            "components": [{"type": 1, "components": [
                {"type": 2, "style": 1, "label": "clique", "custom_id": "gravacao"}]}],
        })

    url = rest(token, "GET", "/gateway/bot")["url"] + "/?v=10&encoding=json"
    sock = ws_connect(url)
    sock.settimeout(1)
    frames, anon = [], Anon()
    interval, sequence, last_beat = 41.25, None, time.time()
    deadline = time.time() + args.segundos
    print(f"gravando por {args.segundos} s; faça as ações no servidor de teste")
    while time.time() < deadline:
        if time.time() - last_beat >= interval:
            ws_send(sock, json.dumps({"op": 1, "d": sequence}))
            last_beat = time.time()
        try:
            text = ws_recv(sock)
        except socket.timeout:
            continue
        if text is None:
            break
        frame = json.loads(text)
        sequence = frame.get("s") or sequence
        if frame["op"] == 10:
            interval = frame["d"]["heartbeat_interval"] / 1000
            ws_send(sock, json.dumps({"op": 2, "d": {
                "token": token, "intents": INTENTS,
                "properties": {"os": "linux", "browser": "supernova", "device": "supernova"}}}))
        elif frame["op"] == 0:
            print("evento:", frame["t"])
        if frame["op"] == 0 and frame.get("t") == "INTERACTION_CREATE":
            data = frame["d"]
            # Responde para o clique não aparecer como falha.
            rest(token, "POST", f"/interactions/{data['id']}/{data['token']}/callback",
                 {"type": 6})
        frames.append(frame)
    sock.close()

    os.makedirs(OUT, exist_ok=True)
    by_kind = {}
    for frame in frames:
        kind = "gateway_" + (frame.get("t") or {10: "hello", 11: "heartbeat_ack"}.get(frame["op"], f"op{frame['op']}")).lower()
        by_kind.setdefault(kind, []).append(anon.walk(frame))
    for kind, items in sorted(by_kind.items()):
        with open(os.path.join(OUT, kind + ".json"), "w", encoding="utf-8") as out:
            json.dump(items, out, ensure_ascii=False, indent=2)
        print(f"{kind}: {len(items)}")
    with open(os.path.join(OUT, "_manifest.json"), "w", encoding="utf-8") as out:
        json.dump({"captured_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "sanitized": True,
                   "duration_seconds": args.segundos, "categories": sorted(by_kind)},
                  out, ensure_ascii=False, indent=2)
    print("revise os arquivos em", os.path.normpath(OUT), "antes de usá-los nos testes")


if __name__ == "__main__":
    main()
