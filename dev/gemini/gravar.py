#!/usr/bin/env python3
"""Grava, contra a API real do Gemini, as respostas que os testes servem.

Roda à mão, quando o cliente ou o modelo mudar (PRD-A):

    python3 -I dev/gemini/gravar.py --env /caminho/.env.bench

Exercita cada chamada de llm/gemini_media: TTS, leitura inline, upload em
partes da Files API, estado do arquivo, leitura pelo arquivo, remoção, um
erro proposital e a lista de modelos. O áudio é sintético (o próprio TTS lê
uma frase fixa); nenhuma voz de pessoa sai daqui.

As fixtures são anonimizadas antes de gravar: sem chave, ids de upload e de
arquivo trocados por marcadores, áudio base64 encurtado. A chave nunca é
impressa.
"""

import argparse
import base64
import json
import os
import re
import time
import urllib.error
import urllib.request

BASE = "https://generativelanguage.googleapis.com"
READER = "gemini-3.5-flash-lite"
SPEECH = "gemini-3.8-flash-lite-tts"
PHRASE = ("Olá! Este é um áudio de teste da Supernova. Um, dois, três. "
          "Agora uma frase um pouco mais longa, para que o arquivo passe de duzentos e cinquenta e seis quilobytes "
          "e o envio aconteça em mais de uma parte. Quatro, cinco, seis.")
INSTRUCTION = (
    "Transcreva este áudio em português do Brasil. REGRAS OBRIGATÓRIAS:"
    "\n1. Produza SOMENTE a transcrição literal do que foi dito."
    "\n2. NÃO inclua timestamps."
    '\n3. Inicie a resposta exatamente com "Transcrição do áudio" seguido de quebra de linha.'
    '\n4. Finalize exatamente com "Fim da transcrição".'
)

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "test", "fixtures", "gemini")


def load_key(path):
    for line in open(path, encoding="utf-8"):
        if line.startswith("GEMINI_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("GEMINI_API_KEY não está em " + path)


def call(key, method, url, body=None, headers=None):
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("x-goog-api-key", key)
    for name, value in (headers or {}).items():
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read()


UPLOAD_ID = re.compile(r"upload_id=[^&\"]+")
FILE_ID = re.compile(r"files/[a-z0-9]+")


def anonymize(text, file_ids):
    text = UPLOAD_ID.sub("upload_id=FIXTURE", text)
    for real, fake in file_ids.items():
        text = text.replace(real, fake)
    text = re.sub(r'"responseId":\s*"[^"]*"', '"responseId": "fixture"', text)
    return text


def shorten_audio(obj):
    """Troca o base64 de áudio por um trecho curto, mantendo a forma."""
    if isinstance(obj, dict):
        return {
            k: (v[:48] + "...(encurtado)" if k == "data" and isinstance(v, str) and len(v) > 64 else shorten_audio(v))
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [shorten_audio(x) for x in obj]
    return obj


def save(name, method, path, request_headers, status, headers, body, file_ids, note=""):
    wanted = {"content-type", "x-goog-upload-url", "x-goog-upload-status",
              "x-goog-upload-chunk-granularity", "x-goog-upload-control-url"}
    keep = {k.lower(): v for k, v in headers.items() if k.lower() in wanted}
    text = body.decode("utf-8", "replace")
    try:
        parsed = shorten_audio(json.loads(text)) if text.strip() else None
        text = json.dumps(parsed, ensure_ascii=False, indent=2) if parsed is not None else ""
    except json.JSONDecodeError:
        pass
    fixture = {
        "note": note,
        "request": {
            "method": method,
            "path": anonymize(path, file_ids),
            "headers": {k: anonymize(v, file_ids) for k, v in request_headers.items()},
        },
        "response": {
            "status": status,
            "headers": {k: anonymize(v, file_ids) for k, v in keep.items()},
            "body": anonymize(text, file_ids),
        },
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name + ".json"), "w", encoding="utf-8") as fh:
        json.dump(fixture, fh, ensure_ascii=False, indent=2)
    print(f"{name}: {status}")


def long_wav(wav, at_least):
    """O mesmo áudio repetido num WAV válido de pelo menos `at_least` bytes."""
    import struct
    pos = wav.find(b"data")
    header, pcm = wav[:pos], wav[pos + 8:]
    data = pcm
    while len(data) + pos + 8 < at_least:
        data += pcm
    header = header[:4] + struct.pack("<I", pos + 8 + len(data) - 8) + header[8:]
    return header + b"data" + struct.pack("<I", len(data)) + data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True)
    key = load_key(parser.parse_args().env)
    file_ids = {}

    # 1. TTS: a frase fixa vira áudio (WAV).
    tts_path = f"/v1beta/models/{SPEECH}:generateContent"
    tts_body = {
        "contents": [{"parts": [{"text": PHRASE}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": "Kore"}}},
        },
    }
    status, headers, body = call(key, "POST", BASE + tts_path, json.dumps(tts_body).encode(), {"content-type": "application/json"})
    save("tts", "POST", tts_path, {}, status, headers, body, file_ids, "TTS da frase fixa")
    if status != 200:
        raise SystemExit("TTS falhou; veja test/fixtures/gemini/tts.json")
    part = json.loads(body)["candidates"][0]["content"]["parts"][0]
    inline = part.get("inlineData") or part.get("inline_data")
    audio = base64.b64decode(inline["data"])
    mime = (inline.get("mimeType") or inline.get("mime_type") or "audio/wav").split(";")[0]
    print(f"áudio sintético: {len(audio)} bytes, {mime}")

    # 2. Leitura inline.
    read_path = f"/v1beta/models/{READER}:generateContent"
    def read_body(medium):
        return json.dumps({
            "system_instruction": {"parts": [{"text": INSTRUCTION}]},
            "contents": [{"role": "user", "parts": [medium]}],
        }).encode()
    status, headers, body = call(key, "POST", BASE + read_path,
                                 read_body({"inline_data": {"mime_type": mime, "data": base64.b64encode(audio).decode()}}),
                                 {"content-type": "application/json"})
    save("read_inline", "POST", read_path, {}, status, headers, body, file_ids, "transcrição do áudio sintético, inline")

    # 3. Upload em partes. A API anuncia o tamanho do bloco
    # (x-goog-upload-chunk-granularity, 8 MiB na gravação de 24/11/2026);
    # para haver mais de uma parte, o áudio é repetido até passar disso,
    # num WAV válido.
    big = long_wav(audio, 9_000_000)
    print(f"áudio para o upload: {len(big)} bytes")
    status, headers, body = call(key, "POST", BASE + "/upload/v1beta/files",
                                 json.dumps({"file": {"display_name": "supernova-media"}}).encode(),
                                 {"content-type": "application/json",
                                  "x-goog-upload-protocol": "resumable",
                                  "x-goog-upload-command": "start",
                                  "x-goog-upload-header-content-length": str(len(big)),
                                  "x-goog-upload-header-content-type": mime})
    lowered = {k.lower(): v for k, v in headers.items()}
    upload_url = lowered.get("x-goog-upload-url")
    part_size = int(lowered.get("x-goog-upload-chunk-granularity", "8388608"))
    save("upload_start", "POST", "/upload/v1beta/files",
         {"x-goog-upload-protocol": "resumable", "x-goog-upload-command": "start"},
         status, headers, body, file_ids, "início do upload resumable")
    if not upload_url:
        raise SystemExit("sem x-goog-upload-url")
    offset, n = 0, 0
    final = None
    while offset < len(big):
        chunk = big[offset:offset + part_size]
        last = offset + len(chunk) >= len(big)
        command = "upload, finalize" if last else "upload"
        status, headers, body = call(key, "POST", upload_url, chunk,
                                     {"x-goog-upload-offset": str(offset), "x-goog-upload-command": command})
        if last:
            final = body
            for real in set(FILE_ID.findall(body.decode())):
                file_ids.setdefault(real, "files/fixture")
        n += 1
        save(f"upload_part_{n}", "POST", "/upload/resumable",
             {"x-goog-upload-offset": str(offset), "x-goog-upload-command": command},
             status, headers, body, file_ids, f"parte {n} ({len(chunk)} bytes)")
        offset += len(chunk)
    file = json.loads(final)["file"]
    name, uri = file["name"], file["uri"]

    # 4. Estado até ACTIVE.
    for attempt in range(30):
        status, headers, body = call(key, "GET", BASE + "/v1beta/" + name)
        state = json.loads(body).get("state")
        if attempt == 0 or state == "ACTIVE":
            save("file_" + str(state).lower(), "GET", "/v1beta/" + name, {}, status, headers, body, file_ids, "estado do arquivo")
        if state == "ACTIVE":
            break
        time.sleep(2)

    # 5. Leitura pelo arquivo.
    status, headers, body = call(key, "POST", BASE + read_path,
                                 read_body({"file_data": {"mime_type": mime, "file_uri": uri}}),
                                 {"content-type": "application/json"})
    save("read_file", "POST", read_path, {}, status, headers, body, file_ids, "transcrição pelo arquivo da Files API")

    # 6. Remoção, e o arquivo já removido.
    status, headers, body = call(key, "DELETE", BASE + "/v1beta/" + name)
    save("file_delete", "DELETE", "/v1beta/" + name, {}, status, headers, body, file_ids, "remoção")
    status, headers, body = call(key, "GET", BASE + "/v1beta/" + name)
    save("file_gone", "GET", "/v1beta/" + name, {}, status, headers, body, file_ids, "arquivo já removido")

    # 7. Erro proposital: MIME que não existe.
    status, headers, body = call(key, "POST", BASE + read_path,
                                 read_body({"inline_data": {"mime_type": "audio/nao-existe", "data": base64.b64encode(b"x").decode()}}),
                                 {"content-type": "application/json"})
    save("read_error", "POST", read_path, {}, status, headers, body, file_ids, "erro proposital: MIME inválido")

    # 8. Modelos: confirma os ids usados.
    status, headers, body = call(key, "GET", BASE + "/v1beta/models?pageSize=1000")
    names = sorted(m["name"] for m in json.loads(body).get("models", []) if "flash-lite" in m["name"] or "tts" in m["name"] or "transcribe" in m["name"])
    with open(os.path.join(OUT, "models.json"), "w", encoding="utf-8") as fh:
        json.dump({"note": "modelos flash-lite, tts e transcribe na data da gravação", "models": names}, fh, indent=2)
    print("modelos:", ", ".join(names))


if __name__ == "__main__":
    main()
