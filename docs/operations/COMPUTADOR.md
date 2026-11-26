# The agent's computer (`computador`)

The `computador` tool gives the agent a Linux machine of its own. It has:

- a real shell: bash, pipes, Python, `pip install`;
- its own files, kept in a volume;
- a persistent Chromium that it drives by selector or by clicking on a screenshot, and sees through screenshots.

The machine is a separate container, `computador/`. It runs on **gVisor** (`runsc`) by default and holds **no Supernova secrets**: no API keys, no channel tokens, no data from anyone. Supernova sends it requests over HTTP and shows the answers to the model, marked as data rather than instructions.

## Why the security lives where it does

The shell and the browser inside the computer are deliberately not restricted. The protections that matter sit outside the computer, in Supernova:

| Protection | Why |
|---|---|
| Keys and people's data stay out of the computer | A page that tricks the agent cannot take what is not there. |
| gVisor (`runsc`) | Code inside the computer talks to a user-space kernel, not to the host kernel. |
| The service refuses requests that come from a browser (an `Origin` header, or a body that is not JSON) | The computer's own browser can reach the service on `127.0.0.1`, so a malicious page cannot use it to run commands. |
| Capabilities config | Members are denied `computador` by default; admins (`"*"`) get it. |
| A separate network (`br-computador`) plus the host firewall rules below | The computer reaches the internet, but not the host or your LAN. |
| Tool description and answer header | Content from the computer is data. The agent asks before acting outside it. |

What this first version does **not** do yet:

- There is one computer per instance, not one per person. That is fine while only admins have it.
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
   SUPERNOVA_COMPUTER_URL=http://computador:7070
   SUPERNOVA_COMPUTER_TOKEN=<output of: openssl rand -hex 24>
   ```

3. Start it:

   ```sh
   docker compose up -d --build
   ```

   The first build pulls the Playwright image (`v1.65.0-noble`), about 2 GB, and installs the headless Chromium of the alpha Playwright the Playwright MCP needs.

4. Confirm that the agent sees the tool. Ask it, in a chat as admin: "roda `uname -a` no seu computador". The answer should mention `gvisor`.

Without `SUPERNOVA_COMPUTER_URL` the tool is not offered at all. To use plain Docker instead of gVisor, set `SUPERNOVA_COMPUTER_RUNTIME=runc`. Isolation is much weaker that way, so use it only for local testing.

## Keeping the computer off the host and the LAN

Inside its network, the computer can reach the internet. Measured on the pilot host, it can also open connections to every host service that listens on all interfaces (`0.0.0.0`), such as SSH, through the Docker gateway. Services bound to `127.0.0.1` are not reachable.

These two rules close that path. They match only traffic that enters from `br-computador`. Traffic inside that network (Supernova ↔ computer) and replies to established connections are left alone.

Supernova is attached to both networks, but `docker-compose.yml` gives its own network the gateway (`gw_priority`), so Supernova's outbound traffic never enters through `br-computador` and these rules do not touch it. That setting needs Docker Engine 28 and Compose 2.33.1 or newer. Without it, Docker picks the gateway by network name, and `computador_net` sorts first.

```sh
# The computer may not open connections to the host itself.
sudo iptables -I INPUT -i br-computador -m conntrack --ctstate NEW -j DROP
# Nor to private and link-local networks (LAN, other Docker networks, cloud metadata).
sudo iptables -I DOCKER-USER -i br-computador ! -o br-computador \
  -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16 \
  -m conntrack --ctstate NEW -j DROP
```

> These rules were written for this setup but not yet applied on a host. After applying them, run the checks below. To undo them, run the same commands with `-D` instead of `-I`. To keep them across reboots, use your distribution's tool, for example `iptables-persistent`.

Run these checks from inside the computer (ask the agent, or use `docker compose exec computador bash`):

```sh
timeout 2 bash -c '</dev/tcp/172.17.0.1/22' && echo "host still reachable"
curl -sI https://example.com | head -1        # internet still works
```

## Operating it

- **Logs:** `docker compose logs computador`
- **Files and browser profile:** volume `<project>_computador_home`, mounted at `/home/pwuser`. Relative paths used by the agent live in `~/trabalho`.
- **Start over:** `docker compose rm -sf computador && docker volume rm <project>_computador_home`
- **DNS:** Docker's embedded DNS (`127.0.0.11`) does not answer inside gVisor on a user-defined network, so `computador/resolv.conf` is mounted over `/etc/resolv.conf`. It points at public resolvers (1.1.1.1, 8.8.8.8); edit it to use your own.
- **Limits:** 3 GB of RAM (the probes' browser shares it, PRD-S S23), 2 CPUs, 512 processes. Commands run for at most 300 s. Long output is cut at 20,000 characters, page text at 15,000.
- **Cost:** a 1280×800 screenshot cost about 570 prompt tokens on the pilot's provider. Only the last two screenshots of a turn stay in the conversation.

## The probes' servers (`/v1/mcp`)

Supernova's probes (PRD-S) use MCP servers that run here, behind the same token and browser check as `/v1/run`; no port is added.

- **`playwright`**, for web probes: one headless Chromium shared by all of them, a separate browser context (cookies, storage, cache) per probe, closed when it ends, at most two tabs each. The tools that would run code in this service or send this machine's files to a site (`browser_run_code_unsafe`, `browser_file_upload`, `browser_drop`) are not offered, URLs must be `http(s)`, and the browser cannot open pages on `localhost`.
- **`filesystem`**, for disk probes: `@modelcontextprotocol/server-filesystem`, confined to the person's folder `~/pessoas/<hash>/`, started with only `PATH` and `HOME` in its environment.
- Probe files stay in `~/pessoas/<hash>/sondas/<n>/`. `/esquecer` deletes the person's folder. A session nobody used for five minutes is closed.

Versions are pinned in `computador/package.json`; update them by hand, after reading the changelogs. The Playwright MCP always depends on an alpha Playwright, so the service uses that one for its own browser too.

## Tests

- Supernova side: `make test` covers request building, answer rendering, image hand-off and the wiring (no model, no container).
- Computer side, run inside the image on gVisor:

  ```sh
  docker build -t supernova-computador computador/
  docker run --rm --runtime=runsc --cap-drop ALL --security-opt no-new-privileges \
    --shm-size 1g supernova-computador npm test --prefix /opt/computador
  ```
