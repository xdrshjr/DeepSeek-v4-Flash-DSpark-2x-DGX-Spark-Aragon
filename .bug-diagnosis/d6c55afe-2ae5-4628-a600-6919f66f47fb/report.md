# Bug Diagnosis Session

**Session UUID:** d6c55afe-2ae5-4628-a600-6919f66f47fb

**Date:** 2026-08-26 02:45 -05:00

**Mode:** Fully automatic

**Status:** Fixed

## Problem Description

审查并修复双机 DGX Spark 部署中一键启动 LLM 服务链路可能存在的问题。

## Evidence Collected

- Scanner、Reviewer、QA 对启动与健康检查链路进行了三方静态确认。
- `ops/healthcheck.sh` 没有请求超时，只支持 `VLLM_API_KEY`，且未验证匿名请求被拒绝。
- 健康检查仅访问控制面接口，没有执行能覆盖双机 TP 的最小推理。
- Bearer Key 位于 `curl` 参数中，并因 `set -a` 被导出到子进程环境。
- systemd 启动超时小于底层启动器的最坏等待窗口。
- `.env.dspark` 未在启动前验证所有者和权限。
- `Type=oneshot` 的 active 状态不能代表容器始终健康；该风险可通过状态/健康探测缓解，无需重构监管架构。

## Root Cause Analysis

**Primary Hypothesis:**

部署层健康检查没有与底层启动器共享同一套鉴权、超时和可用性语义，导致合法的多密钥配置被误判、鉴权失效被漏判、双机推理故障被控制面接口掩盖。

**Why this causes the problem:**

`ops/start.sh` 将 `ops/healthcheck.sh` 的结果作为“服务已就绪”的最终门禁，但后者只进行无超时的 `/health` 与 `/v1/models` 请求。其单密钥假设与启动器支持的多密钥模式不一致，也没有匿名拒绝断言或真实推理请求。

**Alternative Possibilities:**

1. systemd oneshot 状态可能失真，但 Docker 的 `restart: unless-stopped` 已部分缓解；通过增强状态与 API 验收即可处理。
2. 慢速模型冷启动也会失败，因为 unit 的 1200 秒超时短于启动器的最坏等待窗口。

## Fix Plan

1. 重写部署健康检查的凭据加载和探测门禁：有限超时、单/多密钥兼容、匿名拒绝、真实最小推理，且不在 argv 或子进程环境暴露 Key。
2. 在启动入口校验 `.env.dspark` 是由服务用户持有且 group/other 无权限。
3. 放宽 systemd 启动超时，并让状态命令以真实健康检查为准。
4. 增加脚本级回归测试，覆盖单密钥、多密钥、匿名鉴权失败、无凭据、超时参数和 argv 泄漏。

## Verification Plan

- `bash -n` 检查所有修改的 shell 文件。
- 运行新增的健康检查回归测试。
- 运行项目现有相关测试与 `git diff --check`。
- 将修改同步到主节点，在不中断健康服务的情况下运行 `sudo ./ops/start.sh`，确认匿名请求被拒绝且真实双机推理成功。

## Fix Applied

**Files modified:**

- `ops/lib.sh`：新增 `.env.dspark` 常规文件、所有者和权限校验。
- `ops/healthcheck.sh`：支持单/多密钥、有限请求超时、匿名拒绝断言、双节点容器检查和真实最小推理；凭据不再导出或出现在 `curl` argv。
- `ops/start.sh`、`ops/install.sh`：在启动或安装前拒绝所有者/权限不安全的密钥文件。
- `ops/status.sh`：详细状态输出后追加真实健康验收，以其退出码反映可用性。
- `ops/templates/deepseek-v4-flash.service`：将 systemd 外层启动上限提高到 14400 秒，覆盖首次 JIT 最坏窗口。
- `scripts/test-ops-healthcheck.sh`：增加鉴权和安全回归测试。
- `ops/README.md`：记录增强后的启动门禁。

**Changes:**

修复聚焦已确认的 P0/P1 问题，没有为低优先级的 oneshot 状态失真引入新的常驻监管进程。

## Notes

本次范围限定在部署启动链路；不为低优先级的 oneshot 状态问题引入复杂的双重进程监管。

## Verification

- 修改后的所有 shell 文件通过 `bash -n`。
- 新增的 `scripts/test-ops-healthcheck.sh` 在主节点 Linux 上通过，覆盖单密钥、多密钥、无凭据、匿名访问放行、权限过宽、请求超时参数和 Key argv/env 泄漏。
- 现有 `scripts/test-dspark-api-keys.py`：56/56 通过。
- 现有 `scripts/test-env-normalisation.py`：11/11 通过。
- 完整 `scripts/ci-validate.sh`：通过，包括新增 ops shell 语法门禁和健康检查回归测试。
- systemd 已 `daemon-reload`，`TimeoutStartUSec=4h`。
- 主节点执行 `sudo ./ops/start.sh` 走幂等路径，没有重启健康服务；匿名鉴权断言、主/工作节点容器检查、模型清单和真实一 token 双机推理全部通过。
- 主、工作节点部署副本的 `docker-compose.dspark.yml` 已从 CRLF 规范为 LF；这是完整 CI 暴露出的部署副本换行漂移，不改变 Git 中的 Compose 逻辑。
