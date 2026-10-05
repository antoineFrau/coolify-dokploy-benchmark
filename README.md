# Coolify vs Dokploy — local benchmark harness

Implements the benchmark protocol for choosing between Coolify and Dokploy on an
OVH **D2-8** (4 vCPU / 8 GB / 50 GB). Two identical Ubuntu 24.04 VMs run under
QEMU/KVM on this machine; one gets Coolify, one gets Dokploy, and both are measured
with the same scripts, the same application and the same load generator.

Everything a phase records lands in `results/<vm>/` as JSON, and
`report/aggregate.py` turns those files into the §18 comparison table and the §17
weighted score. No figure in the report is typed in by hand.

---

## Layout

| Path | What it is |
|---|---|
| `vms.conf` | The two VMs: ports, platform, extra port forwards |
| `lib.sh` | Host-side helpers (VM lookup, ssh, result dirs) |
| `vm/` | VM lifecycle: fetch image, create, start, stop, ssh, destroy |
| `app/` | The test application: Next.js + worker + PostgreSQL 16 + Redis 7 |
| `bench/` | Scripts that run **inside** each VM, one per protocol section |
| `host/` | Scripts that run **on this machine**: provision, load test, reboot test |
| `report/` | `aggregate.py` — the comparison table and the weighted score |
| `results/` | Collected measurements (git-ignored) |

### The test application

A realistic stack rather than a hello-world container, as §19 asks for:

```
web (Next.js 15, standalone build)  →  PostgreSQL 16
                                    →  Redis 7 (cache in front of the DB)
worker (Node)                       →  PostgreSQL 16 + Redis 7
```

`/api/items` is the load-test target: Redis cache in front of a Postgres query, so
a request exercises the whole stack. It also returns `marker`, the value in
`app/src/lib/build-marker.ts`. Because the marker is a **source constant**, bumping
it genuinely invalidates the Docker build cache — that is what makes the §10 warm
build honest, and it is how the scripts detect that a deploy has actually landed.

```bash
app/set-marker.sh build-2     # stamp a new marker before each redeploy
```

---

## Requirements

Already verified on this machine: `qemu-system-x86_64`, `qemu-img`, `genisoimage`,
`/dev/kvm`, `docker` (for the k6 load generator), `python3`, `ssh`. Two VMs at
8 GB each run simultaneously here (62 GB RAM, 14 cores, 184 GB free).

---

## Running the benchmark

### 0. One-time setup

```bash
./vm/fetch-image.sh              # Ubuntu 24.04 cloud image + benchmark ssh key
app/make-lockfiles.sh            # only if you change app dependencies
```

### 1. Fresh VMs and the §4 baseline

Run this for **each** VM (`coolify-test`, then `dokploy-test`):

```bash
VM=coolify-test

./vm/create-vm.sh  $VM           # fresh 50 GB disk, 4 vCPU, 8 GB, swap off
./vm/start-vm.sh   $VM --wait
./host/provision.sh $VM          # copies the harness, installs §3 monitoring tools

./vm/ssh.sh $VM 'sudo reboot'; sleep 30
./vm/ssh.sh $VM '/opt/bench/01-baseline.sh'   # §4, settles 2 min then records
```

### 2. §5 Install the platform

```bash
./vm/ssh.sh coolify-test '/opt/bench/02-install.sh coolify'
./vm/ssh.sh dokploy-test '/opt/bench/02-install.sh dokploy'
```

Then reboot, wait five minutes, and take the platform-idle measurement:

```bash
./vm/ssh.sh $VM 'sudo reboot'; sleep 30
./vm/ssh.sh $VM '/opt/bench/03-post-install.sh'    # settles 5 min, then records
```

**Manual step.** Open the dashboard once to create the admin account, then close it:

| Platform | URL |
|---|---|
| Coolify | <http://127.0.0.1:8000> |
| Dokploy | <http://127.0.0.1:3100> |

Do this *before* the idle test — §6 wants an idle control plane, not one you are
poking at.

### 3. §6 Idle for 30 minutes

```bash
./vm/ssh.sh $VM '/opt/bench/04-idle.sh 30'
```

Leave the dashboard closed. The report shows average, min, max and the drift across
the window — the drift is what tells you whether a control plane grows while idle.

### 4. §7–§8 Deploy the stack

Both platforms deploy the **same `app/docker-compose.yml`** from a git repository.
Push `app/` to a repo both VMs can reach (a public GitHub repo is simplest), then
create one Docker Compose application per platform pointing at it:

* **Coolify** — *New Resource → Docker Compose → Public Repository*, compose path
  `/docker-compose.yml`, then set the domain for the `web` service to the VM's
  address so Traefik routes port 80 to it.
* **Dokploy** — *Create Service → Compose → Provider: GitHub/Git*, compose path
  `./docker-compose.yml`, then add a domain for the `web` service on port 3000.

Verify the app answers on the VM's port 80 before measuring:

```bash
curl -s http://127.0.0.1:8080/api/items | head -c 120     # coolify-test
curl -s http://127.0.0.1:18081/api/items | head -c 120     # dokploy-test
```

Then measure the first deployment (§8). The script snapshots before, samples every
two seconds during, waits for the new marker to appear, and snapshots again after a
five-minute settle:

```bash
./vm/ssh.sh $VM '/opt/bench/05-deploy.sh first http://127.0.0.1/api/items \
    "\"marker\":\"build-1\""'
```

It pauses and asks you to press Enter *at the moment* you trigger the deploy in the
dashboard. If you drive the platform's API instead, pass `--trigger "<command>"` and
it times the deploy without you.

### 5. §9 Cold build, §10 warm build

Cold — the script prunes the build cache first:

```bash
app/set-marker.sh build-2 && git -C app commit -am 'bench build-2' && git -C app push
./vm/ssh.sh $VM '/opt/bench/05-deploy.sh cold http://127.0.0.1/api/items \
    "\"marker\":\"build-2\""'
```

Warm — one small source change, full cache available:

```bash
app/set-marker.sh build-3 && git -C app commit -am 'bench build-3' && git -C app push
./vm/ssh.sh $VM '/opt/bench/05-deploy.sh warm http://127.0.0.1/api/items \
    "\"marker\":\"build-3\""'
```

Each writes duration, peak RAM, minimum available RAM, peak CPU, peak load average
and disk growth for the build window, plus a `vmstat 1` log.

### 6. §11 Load test

From this machine, never inside the VM:

```bash
./host/load-test.sh $VM --conns "10 50 100 200" --duration 60s
```

k6 runs in Docker on the host while the VM samples its own CPU and RAM. Results per
level go to `results/<vm>/load/c<N>/` (`summary.json` has rps and p50/p95/p99).

### 7. §12 Memory pressure

Deploy app copies 2…5 in the dashboard. After each one is healthy:

```bash
./vm/ssh.sh $VM '/opt/bench/06-memory-pressure.sh record 2'
```

It prints available RAM and the §12 verdict (comfortable / acceptable / risky / too
close) after every step.

### 8. §13 Disk growth

Record the curve as builds accumulate — after 0, 1, 5, 10 and 20 deployments:

```bash
./vm/ssh.sh $VM '/opt/bench/07-disk-growth.sh record 10'
```

This writes the full `docker system df -v`, a per-directory `du`, and the container
log directory size, so growth can be attributed to images, build cache, volumes or
logs rather than guessed at.

### 9. §14 Reboot recovery

```bash
./host/restart-test.sh $VM /api/items '"marker":"build-3"'
```

Timed from the host: it confirms the VM actually went down, then times ssh, the
dashboard and the app coming back, and records RAM and any container that failed to
restart.

### 10. §15 Failure recovery

```bash
./vm/ssh.sh $VM '/opt/bench/08-failure.sh http://127.0.0.1/api/items \
    "\"marker\":\"build-3\"" web'
```

Default mode crashes the web process through `/api/crash`. **Do not use
`docker kill` as the crash:** Docker 29 treats an externally delivered SIGKILL as an
intentional stop and does not apply the restart policy, so both platforms would
score "never recovered" for a reason that has nothing to do with them. (`--kill` is
still available if you want that on record, and `--docker-restart` restarts the
daemon.) Recovery is measured twice — user-visible HTTP downtime probed at 20 Hz,
and Docker's own `RestartCount`/`StartedAt`.

Note by hand afterwards whether the dashboard surfaced the failure and whether its
status was accurate; no script can judge that.

### 11. §16 Long idle

```bash
./vm/ssh.sh $VM 'nohup /opt/bench/04-idle.sh 360 300 long-idle &>/dev/null &'
```

Six hours, one sample every five minutes, into its own phase file. Twelve or
twenty-four hours is better if you can spare the time — the report shows RAM drift
and disk growth across the whole window.

### 12. Collect and report

```bash
./host/pull-results.sh coolify-test
./host/pull-results.sh dokploy-test
python3 report/aggregate.py
```

Writes `results/report.md`: the §18 table, the §11 load figures, the §13 disk curve,
the §12 pressure curve, the §15 recovery figures, and the §17 weighted score.

For the 5% usability weight, score each platform yourself:

```bash
echo '{"usability_score": 7, "notes": "..."}' > results/coolify-test/manual.json
```

---

## Keeping the comparison fair

The §2 rules are enforced where they can be:

* Both VMs come from the same cloud image, with the same 4 vCPU / 8 GB / 50 GB, swap
  off, unattended-upgrades disabled, and the same monitoring tools.
* `create-vm.sh` always rebuilds the disk from scratch, so neither platform is ever
  measured against a VM that has been in use longer than the other.
* The same application, the same lockfiles, the same `postgres:16` and `redis:7`,
  the same compose file, deployed the same way on both.
* Every phase reboots or settles for the interval the protocol specifies.

Two things it cannot equalise, both worth stating in any write-up:

* **Docker version.** Each installer brings its own. `install.json` records what
  each VM ended up with — check it before trusting a build-time difference.
* **Control-plane composition.** Coolify and Dokploy each ship their own PostgreSQL,
  Redis and proxy. That *is* the overhead being compared, so it is not corrected
  for, but it explains why idle RAM is hundreds of MB rather than tens.

### What the numbers do and do not transfer

* **RAM and disk transfer well.** The VM has the same memory and disk as the D2-8,
  and the figures that matter (`free -m`, `df /`, `du /var/lib/docker` +
  `/var/lib/containerd`) are measured the same way they would be on the server.
* **Build times are slower here than on real hardware** — they run on a QEMU disk
  with `cache=none`, so the host page cache is not inflating them. Compare the two
  platforms against each other, not against an OVH stopwatch.
* **Absolute requests/sec is capped by QEMU's user-mode networking.** Both VMs are
  measured through the identical path, so the comparison holds; read the rps as a
  floor. `./host/load-test.sh $VM --also-in-vm` repeats the heaviest level from
  inside the guest for an uncapped figure.
* **Docker 29 stores images under `/var/lib/containerd`,** not `/var/lib/docker`, so
  the disk measurements count both. A §13 number that only looked at
  `/var/lib/docker` would undercount by several GB.

---

## Housekeeping

```bash
./host/reset-results.sh $VM --local-too   # clear measurements between runs
./vm/stop-vm.sh    $VM                    # clean ACPI shutdown
./vm/destroy-vm.sh $VM                    # delete the disk; results/ untouched
```

A no-platform reference point is also available — plain Docker, same app — which
turns "platform overhead" into a measured difference instead of an estimate:

```bash
./host/provision.sh $VM control
./vm/ssh.sh $VM '/opt/bench/02-install.sh control'
./vm/ssh.sh $VM '/opt/bench/09-control-deploy.sh build-1 80'
```
