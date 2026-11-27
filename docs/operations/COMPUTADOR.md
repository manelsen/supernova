# The agent's computer (`computador`)

The `computador` tool gives the agent a Linux machine for its person: **each person has a computer of their own** (PRD-K, K-04). It has:

- a real shell: bash, pipes, Python, `pip install`;
- its own files, kept in a volume;
- a persistent Chromium that it drives by selector or by clicking on a screenshot, and sees through screenshots.

Each machine is a container made from the `computador/` image by the dispatcher (`despachante/`), with its own volume and its own network. It runs on **gVisor** (`runsc`) and holds **no Supernova secrets**: no API keys, no channel tokens, nobody else's data. Supernova sends it requests through the dispatcher and shows the answers to the model, marked as data rather than instructions.

A person's computer turns on at their first action (1.5 to 4 s) and off after 15 minutes idle; files and browser sessions stay in the volume. At most 4 are on at once: a fifth person waits up to a minute for a place, or takes the place of the computer idle longest (idle at least a minute, with nothing running).

## Why the security lives where it does

The shell and the browser inside the computer are deliberately not restricted. The protections that matter sit outside the computer, in Supernova:

| Protection | Why |
|---|---|
| Keys and people's data stay out of the computer | A page that tricks the agent cannot take what is not there. |
| gVisor (`runsc`) | Code inside the computer talks to a user-space kernel, not to the host kernel. |
| The service refuses requests that come from a browser (an `Origin` header, or a body that is not JSON) | The computer's own browser can reach the service on `127.0.0.1`, so a malicious page cannot use it to run commands. |
| Capabilities config | Members are denied `computador` by default; admins (`"*"`) get it. |
| A network per computer (bridges `brc-*`) plus the host firewall rules below | The computer reaches the internet, but not the host, your LAN, Supernova or anyone else's computer. |
| Tool description and answer header | Content from the computer is data. The agent asks before acting outside it. |

What this first version does **not** do yet:

- Logins and captchas cannot be handed over to a person: there is no screen to watch (noVNC).
- Confirmation before outside effects is asked for in the agent's instructions, but not enforced by code.

## Turning it on

1. Install gVisor on the host and register it with Docker. The [gVisor install guide](https://gvisor.dev/docs/user_guide/install/) ends with `sudo runsc install && sudo systemctl reload docker`. Check that it worked:

   ```sh
   docker run --rm --runtime=runsc alpine dmesg | head -1   # "Starting gVisor..."
   ```

2. Add the following to `.env`:

   ```sh
   COMPOSE_PROFILES=computador
   SUPERNOVA_COMPUTER_URL=http://despachante:7071
   SUPERNOVA_COMPUTER_TOKEN=<output of: openssl rand -hex 24>
   SUPERNOVA_COMPUTADOR_TOKEN_INTERNO=<another output of: openssl rand -hex 24>
   SUPERNOVA_SAIDA_TOKEN=<another>
   SUPERNOVA_SAIDA_CREDENCIAL=<another>
   ```

   Supernova talks to the **dispatcher** (`despachante`) with the first token; the dispatcher talks to the computer with the second, which Supernova never sees. See [The dispatcher](#the-dispatcher-despachante).

3. Start it:

   ```sh
   docker compose up -d --build
   ```

   The first build pulls the Playwright image (`v1.65.0-noble`), about 2 GB, and installs the headless Chromium of the alpha Playwright the Playwright MCP needs.

4. Confirm that the agent sees the tool. Ask it, in a chat as admin: "roda `uname -a` no seu computador". The answer should mention `gvisor`.

Without `SUPERNOVA_COMPUTER_URL` the tool is not offered at all. To use plain Docker instead of gVisor, set `SUPERNOVA_COMPUTER_RUNTIME=runc`. Isolation is much weaker that way, so use it only for local testing.

## Keeping the computer off the host and the LAN

Inside its network, the computer can reach the internet. Measured on the pilot host, it can also open connections to every host service that listens on all interfaces (`0.0.0.0`), such as SSH, through the Docker gateway. Services bound to `127.0.0.1` are not reachable.

These two rules close that path. They match only traffic that enters from a computer's bridge (`brc-*`, one per person) or SearXNG's (`br-computador`). Replies to established connections are left alone.

**Supernova is on no computer's network** (PRD-K), and **computers do not see each other** (K-I4): each has a network of its own, and Docker keeps bridges apart. Supernova's calls go through the dispatcher, which joins each computer's network but listens only on Supernova's side. Loopback inside the computer is its own service; the rules do not cover it. Two checks in the computer do:

- **Its browsers reach nothing internal.** Every request of the computer's browser and of the probes' browser contexts goes through `computador/rede.mjs`: loopback (`localhost`, `127.0.0.0/8`, `::1`), `0.0.0.0`, private and link-local ranges (IPv4 and IPv6, including IPv4 written inside IPv6), carrier-grade NAT and multicast are refused, by address or by what a name resolves to. Docker's own names (`supernova`, `searxng`) do not resolve in the computer, which asks public DNS.
- **The service refuses to start without `COMPUTADOR_TOKEN`**, and an empty token refuses every request.

## The way out (`saida`)

Each computer's network is **internal**: no route out. The only way out is the proxy `saida/` (PRD-K, K-05), which the dispatcher puts on every computer's network at a fixed address (`.2`). It has no Docker socket and reaches the internet through a network of its own.

- **The browser** (the service's user, `svc`) goes out with the person's proxy credential (derived from `SUPERNOVA_SAIDA_CREDENCIAL`): any public site, any method. What it may *send* is the browser gate's business (K-06).
- **The shell** runs as another user, `sh`, without the credential. Through the proxy it may only read and download (`CONNECT`, `GET`, `HEAD`) from the factory list (pip, npm, apt, GitHub, crates, Go, RubyGems) and the sites the person approved. The agent asks for a site with `pedir_site`; the person answers in private; an approved site stays on that person's list only (`/permissoes` lists and revokes it).
- **Nothing internal, whatever the credential:** the proxy resolves names itself, once, refuses loopback, private, link-local and similar addresses, and connects to the address it checked.
- **The credential stays with `svc`.** A launcher starts as root with only `CHOWN`, `SETUID`, `SETGID` and `KILL`, hands the service to `svc` and each shell command to `sh`, which gets no token, no credential, and a scratch folder of its own (`~/rascunho`). `sh` cannot read another user's environment.

## The browser gate (`portao`)

What the browser may **send** is decided in the computer, request by request (PRD-K, K10, K-06; `computador/portao.mjs`), with what the person allowed, which Supernova sends with each call:

- **Reading is free:** `GET`, `HEAD`, `OPTIONS`.
- **Using a site** (anything else in the background: searches, likes, a cart) needs the site allowed. The person is asked "Usar o site X" and chooses how long: **1 hour** (a plain "sim"), **24 hours** ("sim 24 horas") or **for good** ("sim sempre"). A site is what a person recognises: `consultas.saude.gov.br` is `saude.gov.br`.
- **Sending a form** (a `POST` navigation, or a click on a send button: a form's submit button, or a button named like *Enviar*, *Confirmar*, *Pagar*) asks **every time**, with what would go: the fields and their values, passwords and similar fields masked. A yes lets one send through and is spent.
- **The probes** never send anything and never ask.
- **No `evaluate`:** the agent cannot run JavaScript in the page (K11).

**The person's files** (K22, K-07): the shell (`sh`) reads `~/trabalho` and cannot change it; it writes in `~/rascunho`. The file actions (`write_file`, `delete_file`) run as `svc`: creating a file passes; overwriting or deleting one asks the person every time, and a yes lets that one change through.

## Passwords and sessions (`/senha`, `entrar`)

A person gives a password to the vault in private, by text: `/senha <site> <user> <password>` (`/senha` lists the sites, never the passwords; `/senha apagar <site>` deletes one). The code takes it before anything else reads the message: it never reaches the model, the history, the inbox log or a file in clear (K-I3; a test seeds a marked password and searches every prompt and file). On Telegram the message with the password is deleted; on other channels the person is asked to delete it. A voice note with a password is refused: transcription goes to an outside service.

The vault is `<data>/agents/<person>/self/cofre.json`, sealed with AES-256-GCM under `SUPERNOVA_COFRE_KEY` (`openssl rand -hex 32` in `.env`; without it, `/senha` keeps nothing). Losing the key loses the passwords: people send them again.

To log in, the agent opens the site's login page and calls `entrar` with the site. Entering an account asks the person first, unless they said "sempre" for that site. The password goes to the computer only in that call; the computer fills the form, sends it, and answers without it. Sessions (cookies) stay in the browser profile, in the person's volume, across turns and restarts; `sair_do_site` clears a site's cookies; `/esquecer` deletes the vault and the volume.

## The screen (`pedir_tela`) and the tunnel

When a page shows a captcha (the computer detects the common ones and tells the agent) or needs something only the person can do, the agent calls `pedir_tela` (K15). The computer opens a screen: a virtual display (Xvfb), a VNC server on it (x11vnc, local only, with a random password only the service's user reads) and noVNC; the browser reopens on it with the same profile, on the same page, still behind the gate. The person gets a link in private (K16): **one use, 15 minutes, their computer only**; they may forward it to whoever helps them. The first visit uses it and sets a cookie for that browser; any other visit finds it used. The VNC password goes in the link's fragment (`#…`), never to a server. When the link ends, or the agent calls `devolver_tela`, the screen closes and the browser goes back to headless. An open screen keeps the computer on.

The link is served by the dispatcher's screen server (port 7073, Supernova's network) through a Cloudflare tunnel (K17): HTTPS, no port opened on the host, and `cloudflared/config.yml` publishes `/tela/*` and nothing else (`scripts/teste-tunel.sh` asks cloudflared itself; CI runs it). To turn it on:

```sh
cloudflared tunnel login
cloudflared tunnel create supernova-tela          # writes the credentials
cloudflared tunnel route dns supernova-tela tela.example.org
cp ~/.cloudflared/<id>.json cloudflared/credentials.json
```

and in `.env`: `COMPOSE_PROFILES=computador,tela` and `SUPERNOVA_TELA_URL=https://tela.example.org`. Without it, `pedir_tela` answers that the screen is not set up.

The request's first sentence is written by the code from what the gate saw, at most 140 characters (what a screen reader says first). When the gate refuses inside a background task, no request is made: the agent asks in the conversation.

`scripts/teste-saida.sh` checks all this with real computers on gVisor (internet needed): the shell reaches pip and npm and an approved site, not others; a site Ana approved does not open for Bia; there is no way out around the proxy; the shell finds the credential nowhere; the browser goes out.

SearXNG is attached to two networks: it leaves for the internet through `br-computador` (`gw_priority` in `docker-compose.yml`, which needs Docker Engine 28 and Compose 2.33.1 or newer), and Supernova asks it on its own network. No computer is on either.

```sh
for bridge in 'brc+' br-computador; do
  # No new connections to the host itself.
  sudo iptables -I INPUT -i "$bridge" -m conntrack --ctstate NEW -j DROP
  # Nor to private and link-local networks (LAN, other Docker networks, cloud metadata).
  sudo iptables -I DOCKER-USER -i "$bridge" ! -o "$bridge" \
    -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16 \
    -m conntrack --ctstate NEW -j DROP
done
```

`brc+` matches every bridge whose name starts with `brc`: the dispatcher names each computer's bridge `brc-` and 11 characters of the person's hash. If the `br-computador` rules from the shared computer are already in place, run the loop for `brc+` only.

> These rules were written for this setup but not yet applied on a host. After applying them, run the checks below. To undo them, run the same commands with `-D` instead of `-I`. To keep them across reboots, use your distribution's tool, for example `iptables-persistent`.

Run these checks from inside a computer (ask the agent, or `docker exec -it computador-<hash> bash`):

```sh
timeout 2 bash -c '</dev/tcp/172.17.0.1/22' && echo "host still reachable"
curl -sI https://example.com | head -1        # internet still works
```

## Operating it

- **Which are on:** `docker ps --filter label=supernova.despachante=1`. Each is `computador-<hash>`, where `<hash>` is the first 16 hex digits of the SHA-256 of the person's id.
- **Logs:** `docker compose logs despachante`; one computer's: `docker logs computador-<hash>`.
- **Files and browser profile:** volume `computador-<hash>`, mounted at `/home/pwuser`. The file actions' relative paths live in `~/trabalho`; shell commands run in `~/rascunho` (user `sh`); the probes' files are in `~/pessoas/<hash>/`.
- **Start one person over:** `/esquecer` does it (container, volume and network go). By hand: `POST /v1/apagar` to the dispatcher.
- **DNS:** Docker's embedded DNS (`127.0.0.11`) does not answer inside gVisor on a user-defined network, so the dispatcher mounts `computador/resolv.conf` over each computer's `/etc/resolv.conf`, read-only. It points at public resolvers (1.1.1.1, 8.8.8.8); edit it to use your own, then restart the computers.
- **Limits:** 1.5 GB of RAM per computer (the probes' browser shares it, PRD-S S23), 2 CPUs, 512 processes, 4 computers on at once. Commands run for at most 300 s. Long output is cut at 20,000 characters, page text at 15,000.
- **Cost:** a 1280×800 screenshot cost about 570 prompt tokens on the pilot's provider. Only the last two screenshots of a turn stay in the conversation.

## The dispatcher (`despachante`)

`despachante/` is a small Node service, and the **only container with the Docker socket**; Supernova never has it (PRD-K, K-I6; a test reads `docker-compose.yml`). It:

- carries Supernova's calls to a person's computer (`POST /v1/pessoas/<hash>/run`, `POST /v1/pessoas/<hash>/mcp`), turning it on first if needed and adding the computer's token;
- turns computers off after 15 minutes idle, keeps at most 4 on, and deletes a person's computer with its volume and network (`POST /v1/apagar`, which `/esquecer` calls). Also `POST /v1/ligar`, `/v1/desligar` with `{"pessoa": "<16 hex digits>"}`, and `GET /v1/estado`.

The API takes a person's hash and nothing else: image, runtime, memory (1.5 GB), network, volume, capabilities and DNS are fixed in its code. The image is the one the `computador` service builds and never runs (`supernova-computador:latest`), pinned to its id when the dispatcher starts; after rebuilding the computer image, restart the dispatcher. It only touches containers, volumes and networks it made (label `supernova.despachante`).

Each computer gets a network of its own (`computador-<hash>`, bridge `brc-…`), which the dispatcher joins; it listens only on its address on Supernova's network, which it asks Docker for at start. A computer finds nothing to connect to. `scripts/teste-rede-despachante.sh` checks this with real Docker (CI runs it on runc; here it also passed on gVisor):

```
ok   Supernova reaches Ana's computer through the dispatcher
ok   Supernova reaches Bia's computer through the dispatcher
ok   Ana's computer reaches the internet (public DNS)
ok   Supernova does not reach Ana's computer directly
ok   Ana's computer does not reach Bia's computer
ok   Ana's computer does not reach Bia's computer by name
ok   Ana's computer does not reach Supernova by name
ok   Ana's computer does not reach Supernova by address
ok   Ana's computer does not reach the dispatcher on its network
ok   Ana's computer does not reach the dispatcher on Supernova's side
ok   forgetting Ana deletes her computer
ok   no container of Ana's left
ok   no volume of Ana's left
ok   no network of Ana's left
ok   Bia's computer is still there
```

**Upgrading from the shared computer:**

1. Add `SUPERNOVA_COMPUTADOR_TOKEN_INTERNO`, `SUPERNOVA_SAIDA_TOKEN` and `SUPERNOVA_SAIDA_CREDENCIAL` to `.env` (each `openssl rand -hex 24`) and change `SUPERNOVA_COMPUTER_URL` to `http://despachante:7071`.
2. `docker compose up -d --build --remove-orphans`. The old shared container goes; its volume stays.
3. Move each person's files to their own volume: `scripts/migrar-computadores-por-pessoa.sh`. It copies `~/pessoas/<hash>/` from the old volume (`<project>_computador_home`) to `computador-<hash>`. The shared `~/trabalho` and browser profile are not moved.
4. Apply the firewall rules above (`brc+`).
5. When satisfied, `docker volume rm <project>_computador_home`.

- **Logs:** `docker compose logs despachante`
- **Tests:** `docker build -t sn-despachante despachante/ && docker run --rm sn-despachante npm test --prefix /opt/despachante` (a fake Docker), then `scripts/teste-rede-despachante.sh`.

## The probes' servers (`/v1/mcp`)

Supernova's probes (PRD-S) use MCP servers that run here, behind the same token and browser check as `/v1/run`; no port is added.

- **`playwright`**, for web probes: one headless Chromium in the person's computer, a separate browser context (cookies, storage, cache) per probe, closed when it ends, at most two tabs each. The tools that would run code in this service or send this machine's files to a site (`browser_run_code_unsafe`, `browser_file_upload`, `browser_drop`) are not offered, URLs must be `http(s)`, and the browser cannot open pages on `localhost`.
- **`filesystem`**, for disk probes: `@modelcontextprotocol/server-filesystem`, confined to the person's folder `~/pessoas/<hash>/`, started with only `PATH` and `HOME` in its environment.
- Probe files stay in `~/pessoas/<hash>/sondas/<n>/`. `/esquecer` deletes the person's whole computer. A session nobody used for five minutes is closed.

### The probes' search (`buscar`)

Web probes search with `buscar`. By default it asks **SearXNG**, a self-hosted metasearch engine (AGPL-3.0, used unmodified) that the `computador` profile starts as the `searxng` container, with `searxng/settings.yml`. It sits on the computer's network: it reaches the internet but not the host or the LAN (the firewall rules above cover it too), and no port is published. Optionally set a secret in `.env`:

```sh
SUPERNOVA_SEARXNG_SECRET=<output of: openssl rand -hex 24>
```

SearXNG asks other engines from this one IP, and some of them answer with captchas or refusals (on the first test, DuckDuckGo and Wikidata did); it keeps going with the rest. When results get poor, switch to **Tavily** (about 1,000 free credits a month, no card):

```sh
SUPERNOVA_SEARCH_PROVIDER=tavily
SUPERNOVA_TAVILY_API_KEY=tvly-...
```

The search request leaves from Supernova; the Tavily key never goes to the computer.

Versions are pinned in `computador/package.json`; update them by hand, after reading the changelogs. The Playwright MCP always depends on an alpha Playwright, so the service uses that one for its own browser too.

## Tests

- Supernova side: `make test` covers request building, answer rendering, image hand-off and the wiring (no model, no container).
- Computer side, run inside the image on gVisor:

  ```sh
  docker build -t supernova-computador computador/
  docker run --rm --runtime=runsc --cap-drop ALL --security-opt no-new-privileges \
    --shm-size 1g supernova-computador npm test --prefix /opt/computador
  ```
