# Coolify vs Dokploy: what they actually cost you when they're doing nothing

*5 October 2026 — measured on identical 4 vCPU / 8 GB / 50 GB Ubuntu 24.04 VMs*

I'm about to put a handful of small production services on an OVH D2-8: 4 vCPU, 8 GB
of RAM, about 50 GB of disk. Self-hosted PaaS, so Coolify or Dokploy. Every
comparison I could find online ranks them on features. None of them told me the
thing I actually needed to know:

> After I install this, how much of my 8 GB is left?

On a 64 GB machine that question is a rounding error. On 8 GB it decides how many
apps I can run. So I measured it.

This post covers the **idle** result: both platforms installed, no application
deployed, nobody logged into the dashboard. It's the floor — the rent you pay
before you host anything. Build and load numbers come later.

---

## How I measured it

Two VMs under QEMU/KVM, built from the same Ubuntu 24.04 cloud image, each given
4 vCPU, 8 GB RAM, a fresh 50 GB disk, and swap disabled. Same monitoring tools on
both. Both were rebooted before the baseline, installed with the platform's own
official installer, rebooted again, left to settle for five minutes, and then
sampled once a minute for half an hour.

The dashboards were never opened. No admin account was created on either. That
keeps both platforms in the same state, and it's what an idle test is supposed to
be — the protocol's own words are *"do not open the dashboard repeatedly."*

Every sample records `free -m`, CPU from `/proc/stat`, load average, `df /`,
`docker system df`, and per-container memory and CPU. The headline figure is
deliberately `free -m` and not `docker stats`, because the real question is how
much memory the server has left, not what Docker admits to using.

Coolify: 25 samples over 27 minutes. Dokploy: 24 samples over 26 minutes.

---

## The results

| | **Coolify** | **Dokploy** |
|---|---:|---:|
| Fresh Ubuntu baseline RAM | 154 MB | 167 MB |
| **Total idle RAM used** | **545 MB** | **1061 MB** |
| Platform cost over baseline | 393 MB | 870 MB |
| Available RAM | 6907 MB | 6557 MB |
| RAM drift across the window | −23 MB | −2 MB |
| **Idle CPU busy, average** | **8.57 %** | **1.31 %** |
| Idle CPU, median / peak | 6.5 % / 28.0 % | 1.3 % / 2.9 % |
| **Disk consumed by install** | **+3.76 GB** | **+4.97 GB** |
| Docker images | 3.13 GB | 3.90 GB |
| Install time | 59 s | 87 s |
| Containers at idle | 6 | 3 |

### Memory: Coolify wins by half a gigabyte

```
Coolify   545 MB   coolify 353 · realtime 93 · db 57 · proxy 17 · redis 16 · sentinel 6
Dokploy  1061 MB   dokploy 865 · traefik 112 · postgres 61
```

Dokploy runs fewer containers but one of them is enormous. Its main application
container alone uses 865 MB — more than Coolify's entire control plane including
its PostgreSQL, its Redis, its proxy and its websocket server.

On 8 GB, the 516 MB difference is about 6.5 % of the whole machine. In practical
terms that's three more small Node containers you can run before things get tight.

Neither platform leaks. Across half an hour both drifted *downward* slightly
(−23 MB and −2 MB), which is settling, not growth. That was the thing I most
expected to find and didn't.

### CPU: the result I didn't expect

Coolify never goes quiet. Idle, with no apps and nobody watching, it averages
**8.57 % of 4 vCPU** and spikes to 28 %. Dokploy sits at **1.31 %**.

The culprit is visible in the per-container numbers: `coolify-realtime`, its
websocket server, was burning 21 % CPU in the final sample, with the main Laravel
container adding more on top.

My first instinct was that this had to be measurement error — my host was under
memory pressure for part of the run, and a starved guest can report stolen time as
busy time. It isn't error, for two reasons. The per-container cgroup figures, which
exclude steal entirely, independently agree: Coolify's containers sum to 24.4 % of
one core, which is 6 % of a 4-vCPU box, right in line with the system figure.
Dokploy's sum to 2 %, or 0.5 % of the box. And the two measurement windows
overlapped on the same host, so any contention would have inflated both equally.

It's real. Roughly 0.34 of a vCPU, permanently, for a platform that is doing
nothing.

### Disk: Coolify again, by 1.2 GB

Coolify's install costs 3.76 GB, Dokploy's 4.97 GB, measured by `df` on the root
filesystem. On a 50 GB disk that's 2.4 % of your total budget, before a single
image of your own gets built.

I'd treat this as the least important of the three numbers, though. Install
footprint is a one-off; what will actually eat a 50 GB disk is accumulated build
cache and old images across dozens of deployments. That's the next measurement, and
I'd expect it to dwarf this difference.

---

## Three things that nearly gave me wrong numbers

Worth writing down, because each would have produced a confident-looking table full
of quietly false figures.

**Neither installer adds your user to the `docker` group.** Coolify's certainly
doesn't. If your collection script shells out to `docker ps` and `docker system
df`, both fail with a permission error — and a naive script records *zero
containers and zero image size* rather than crashing. I caught this mid-run because
Coolify's container count came back empty. Measurement code should fail loudly, not
return a plausible zero.

**Docker 29 stores images somewhere else.** It defaults to the containerd
snapshotter, so most image data lives under `/var/lib/containerd`, not
`/var/lib/docker`. Measuring only the traditional path undercounted by 2.7 GB out of
3.8 GB. Related trap: `du` double-counts overlay2 layer content and happily reports
a number larger than the filesystem's own used figure — for Dokploy it claimed
7.97 GB against a real 6.97 GB total. `df` is the number to trust.

**`docker kill` does not test what you think it tests.** On Docker 29, an
externally delivered SIGKILL is treated as an intentional stop, and the restart
policy is not applied. A "does it recover from a crash?" test built on `docker kill`
scores *every* platform as "never recovered", for a reason that has nothing to do
with the platform. A real in-process crash is the only honest trigger. And when you
do measure it, poll fast — recovery here was 1.3 seconds, which a two-second polling
loop would report as no outage at all.

---

## A detail that turned out to matter

The two installers gave me different Docker versions: Coolify installed 29.8.2,
Dokploy installed 28.5.0.

That's not drift. Dokploy's installer pins it, with a comment saying so:

```sh
# Docker version to install and maintain
DOCKER_VERSION="28.5.0"
```

Dokploy is built on Docker Swarm, and Docker 29 broke things for Swarm clusters —
API compatibility and networking among them. So Dokploy holds the line at 28.x.

Two ways to read that. Charitably: they know their dependency and they're protecting
you from a bad upgrade. Less charitably: your container runtime's version is now
decided by your PaaS, and it's a major version behind. If you have opinions about
running current Docker, that's a constraint worth knowing before you install, not
after.

---

## Features: where each one actually wins

The benchmark only measures weight. Features decide whether the thing can do your
job at all.

| | **Coolify** | **Dokploy** |
|---|---|---|
| Licence | Apache 2.0 | Apache 2.0 core, paid enterprise tier |
| Maturity | ~58k GitHub stars, 5 years, v4.x | Younger, v0.28–0.29, moving fast |
| Architecture | Docker + Compose, Laravel/PHP | Docker Swarm, Traefik, TypeScript |
| One-click templates | 280+ | 350+ |
| Multi-server | Yes, Swarm support experimental | Native Swarm clustering |
| Database backups to S3 | Yes, scheduled, one-click | Yes, manual and scheduled |
| **Volume backups** | **No** | **Yes** |
| Teams / RBAC | Teams and roles | Organisations, RBAC; SSO and audit logs are paid |
| Preview deployments | Yes | Yes |
| Built-in monitoring | Yes | Yes, CPU/RAM/disk metrics on by default |
| Infrastructure as code | Community Terraform provider | API |
| Notifications | Multiple connectors | Slack, Discord, Telegram, email |

**Dokploy's real feature wins** are volume backups — a genuine gap in Coolify, and
it bites the moment you have a service storing files on disk rather than in a
database — a larger template library, and Swarm clustering that's native rather than
experimental if you ever grow past one box.

**Coolify's real wins** are maturity and gravity. Five years, a very large user
base, and a Terraform provider. When something breaks at 2 a.m., the odds that
somebody has already written up your exact error are much better. Its backup story
for databases is more polished.

---

## Which I'd pick

**For this box — one 8 GB / 50 GB server, a few Next.js services with Postgres and
Redis — I'd take Coolify.**

The reasoning is specific to the constraint. On 8 GB, 516 MB of extra permanent
overhead is the single most expensive thing in this comparison, and Dokploy is the
one charging it. Dokploy's strongest features are multi-server Swarm clustering and
a bigger template library — neither of which does anything for me on a single
server where I'm deploying my own code, not one-click apps. Add Coolify's maturity
and the fact that it runs current Docker rather than a pinned 28.x, and it's the
better fit.

Coolify's idle CPU is a genuine wart and I'm not going to pretend otherwise.
A third of a vCPU burned permanently on a websocket server with nobody connected is
sloppy. On a 4-vCPU box I can afford it; on a 2-vCPU instance I'd think much harder,
and if I were running something latency-sensitive I'd want to watch it under load
before committing.

**I'd pick Dokploy instead if** any of these were true: I needed volume backups and
didn't want to script them myself; I expected to grow onto multiple servers inside a
year; I wanted a genuinely quiet machine; or I was deploying mostly from the
template library rather than from my own repositories.

### What this recommendation does not yet rest on

Three measurements, out of the eight criteria that matter for an 8 GB box. The
weighted score so far — Coolify 83.1, Dokploy 70.8 — covers idle RAM, idle CPU and
install disk, which together are half the weight I assigned.

The missing half includes the two things most likely to actually hurt on this
hardware: **peak RAM during a build** (an 8 GB box with a Next.js build and a
Postgres running is a real OOM risk) and **disk growth across repeated deploys**
(50 GB disappears fast under accumulated build cache). Either could overturn this.
I'll measure them next, and I'll say so here if the answer changes.

---

*Methodology, scripts and raw measurements are all in this repository: two
reproducible VMs, one script per protocol section, and a report generator that
builds the comparison table straight from the recorded JSON. Every figure above came
out of `results/`; nothing was typed in by hand. Re-run it yourself with
`./vm/fetch-image.sh` and the steps in the README.*

**Sources:** [Dokploy vs Coolify comparison](https://introserv.com/blog/dokploy-vs-coolify-complete-comparison-of-the-best-self-hosted-paas-platforms-for-vps-and-dedicated-servers-2026/) ·
[Dokploy RBAC](https://dokploy.com/features/role-based-access-control) ·
[Dokploy docs](https://docs.dokploy.com/docs/core/installation) ·
[Coolify on OpenAlternative](https://openalternative.co/compare/coolify/vs/dev-push) ·
[Terraform provider for Coolify](https://pkg.go.dev/github.com/coolify-terraform/terraform-provider-coolify) ·
[Docker Swarm in 2026](https://www.virtualizationhowto.com/2026/03/is-docker-swarm-still-safe-in-2026/)
