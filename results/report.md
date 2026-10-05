# Coolify vs Dokploy — benchmark results

Target: 4 vCPU / 8 GB / 50 GB (OVH D2-8 class). Every figure below comes from a file under `results/`; `-` means that measurement was not collected.

## §18 Final comparison

| Measurement | coolify (coolify-test) | dokploy (dokploy-test) |
|---|---:|---:|
| OS baseline RAM used | 154 MB | 167 MB |
| Platform idle RAM (over baseline) | 393 MB | 870 MB |
| Total idle RAM used | 545 MB | 1061 MB |
| Idle RAM drift over the window | -23 MB | -2 MB |
| Idle available RAM | 6907 MB | 6557 MB |
| Idle CPU busy | 8.57 % | 1.31 % |
| Installation disk | 3.76 GB | 4.97 GB |
| Docker images after install | 3.13 GB | 3.90 GB |
| Cold build time | - | - |
| Cold build peak RAM | - | - |
| Cold build min available RAM | - | - |
| Cold build peak CPU | - | - |
| Cold build peak load | - | - |
| Warm build time | - | - |
| Disk growth per build | - | - |
| Disk after last measured build | - | - |
| RAM with the app stack running | - | - |
| App containers RAM | - | - |
| Platform + OS overhead | - | - |
| Max apps with >2 GB free | - | - |
| Reboot: app ready | - | - |
| Reboot: dashboard ready | - | - |
| Failed containers after reboot | - | - |


## §17 Weighted score

| Criterion | coolify-test value | dokploy-test value | coolify-test score | dokploy-test score |
|---|---:|---:|---:|---:|
| idle ram (20%) | 545 | 1061 | 1.000 | 0.514 |
| build peak ram (15%) | - | - | - | - |
| disk usage (20%) | 3.76 | 4.97 | 1.000 | 0.757 |
| disk growth (15%) | - | - | - | - |
| cpu overhead (10%) | 8.57 | 1.31 | 0.153 | 1.000 |
| deploy speed (5%) | - | - | - | - |
| reliability (10%) | - | - | - | - |
| usability (5%) | - | - | - | - |


| Total (0–100) | coolify-test | dokploy-test |
|---|---:|---:|
| weighted | 83.1 | 70.8 |


> Scores are relative: on each criterion the best platform scores 1.0 and the other is scaled against it. Criteria with no measurement are excluded and their weight redistributed. `usability` is manual — put a 0–10 value in `results/<vm>/manual.json` as `{"usability_score": 7}` to include it.


**Not yet measured:** build_peak_ram, deploy_speed, disk_growth, reliability, usability
