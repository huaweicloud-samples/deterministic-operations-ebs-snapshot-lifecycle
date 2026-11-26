# 部署指导书（华为云）

本指导书说明如何使用 Terraform + `huaweicloud` Provider 一键部署「云硬盘分层快照自动化」实践。

## 1. 前置条件
- 已注册华为云并完成实名认证，账户余额充足。
- 本地安装 Terraform ≥ 1.5（`terraform version` 验证）。
- 在「我的凭证 → 访问密钥」创建 AK/SK 并填入部署脚本（**不要写入代码/配置**）：
```bash
export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
export HW_SECRET_KEY="<HW_SECRET_KEY>"
# 临时凭证（推荐）额外导出：
export HW_SECURITY_TOKEN="<TOKEN>"
```
- 确认目标区域（默认 `cn-north-4` 北京四）支持 CBR 磁盘备份、FunctionGraph、RMS。

## 2. 配置变量
编辑 `infra/terraform.tfvars`：
```hcl
region = "cn-north-4"
project_name = "ebs-cbr-automation"
alert_email = "your-email@example.com" # SMN 邮件订阅收件人

evs_volume_type = "GPSSD"
cbr_vault_size_critical = 200
cbr_vault_size_standard = 100
cbr_vault_size_dev = 50

rms_agency_delegated_service = "op_svc_eps" # apply 报错时改 "rms"
```

## 3. 初始化与校验
```bash
cd infra
terraform init # 拉取 huaweicloud provider
terraform validate # 语法/参数校验
terraform plan # 预览资源变更（不收费）
```
> `init/validate/plan` 均为本地操作，不会创建云上资源。

## 4. 部署
```bash
terraform apply
```
按提示输入 `yes`。首次执行会创建 CBR 存储库、EVS 云硬盘等资源（详见第 6 节）。


## 5. 函数代码说明
`src/functions/` 下两个 Python 文件通过 `filebase64` 内联部署，无需单独打包：
- `snapshot_verification/index.py`：校验函数，由 TIMER 每日 06:00 UTC 触发。
- `tier_coordinator/index.py`：协调函数，由 TIMER 每小时触发。

函数运行期凭证由 `functiongraph` 委托注入环境变量（`HUAWEI_ACCESS_KEY` 等），**代码中无真实凭据**。

## 6. 资源规格（apply 前必读）


## 7. 部署后验证
1. 进入 CBR 控制台，确认 3 个存储库已按 `BackupTier` 关联对应 EVS 云硬盘（critical 库 2 块、standard 库 1 块、dev 库 1 块；non-compliant 卷不在任何库中）。
2. 进入 RMS 控制台，确认资源记录器已启用、合规规则 `required-all-tags` 对 `non-compliant` 卷判为不合规。
3. 手动触发（或等待）`snapshot-verification` 函数，确认 LTS 日志输出 `health_status`；人为删掉某卷最新备份后应能收到 SMN 邮件告警。
4. 确认 SMN 邮件订阅已点击确认链接。

## 8. 清理
```bash
terraform destroy
```
> `destroy` 前请确认已无需要保留的备份；OBS 桶设了 `force_destroy=true` 会一并删除。

## 9. 常见问题
- **RMS 委托 apply 报 `invalid delegated service`**：将 `rms_agency_delegated_service` 改为 `rms`，或在控制台创建名为 `rms_tracker_agency` 的委托后引用其名称。
- **函数运行报缺 SDK 包**：在 FunctionGraph 依赖管理中引入 `huaweicloudsdkcbr` / `huaweicloudsdkevs` / `huaweicloudsdksmn` 对应依赖版本。
- **SMN 收不到邮件**：检查订阅是否已“确认订阅”（点击确认邮件）。

## 10. EVS 云硬盘加密（可选）

EVS 启用加密的标准做法是通过 `kms_id` 指定 CMK，但**首次在本区域使用 EVS 加密时，需先在控制台授权 EVS 服务（`op_svc_evs`）访问 KMS**（含对所用 CMK 的 KMS grant），否则创建加密盘会报 `EVS.2264 get Agency's token failed`。该授权由控制台引导自动完成，API/terraform 无法稳定复现。

启用步骤（手动）：
1. 控制台「密钥管理 KMS」→ 对目标密钥授权 `op_svc_evs` 服务（加密/解密/DescribeKey）。
2. 或首次通过 EVS 控制台创建加密盘时，按提示“创建委托”自动授权。
3. 在 `infra/main.tf` 的各 `huaweicloud_evs_volume` 重新加回 `kms_id = huaweicloud_kms_key.evs.id`（并恢复 `huaweicloud_kms_key.evs` 与 `op_svc_evs` 委托资源），再 `terraform apply`。

> 为交付一个**立即可用**的环境，本实践默认未启用 EVS 加密；如合规要求加密，按上述步骤启用即可，其余架构不变。

## 11. 落地已知坑（terraform + huaweicloud provider）

实跑 `terraform apply` 中已验证并规避的若干 provider 行为（供复用时参考）：

- **FunctionGraph 委托服务名是 `op_svc_cff`，不是 `op_svc_functiongraph`**（后者报 `Could not find domain`）。
- **EVS 加密需 `op_svc_evs` KMS 授权**（见第 10 节）。
- **FGS 函数显式绑定 LTS（`log_group_id`/`log_stream_id`）偶发 `FSS.1212 group or stream not existed`**；改为不绑定，由 FunctionGraph 自动创建默认日志组即可。
- **FGS `user_data`（环境变量）必须是字符串**：数值型（如 `2`）报 `FSS.1009 Invalid environment variable`，需写成 `"2"`。
- **TIMER 触发器一旦 `ACTIVE`，API 拒绝元数据更新**（`FSS.1153`）；对 `huaweicloud_fgs_function_trigger` 加 `lifecycle { ignore_changes = [event_data, status] }` 规避 provider 反复 PUT。
- **RMS `required-all-tags` 合规规则需同时给 `TagKeys` 与 `TagValues`**（`TagValues` 为空串数组表示“任意值”），否则报 `RMS.00010004 parameter 'TagValues' missing`。
- **RMS 策略分配依赖资源记录器已启用**：对 `huaweicloud_rms_policy_assignment` 加 `depends_on = [huaweicloud_rms_resource_recorder.main]`，否则报 `RMS.00010091 Resource recorder disabled`。
- **CBR `auto_bind` 不会立即绑定已存在的磁盘**：它只在**下一个备份周期**扫描并绑定未受保护资源。apply 完成后若已到当天定时点，现有卷要等下一次定时才自动绑定。为在部署后立即可用，本实践对各 vault 显式声明 `resources { includes = [...] }` 做初始绑定，并加 `lifecycle { ignore_changes = [resources] }` 防止后续 terraform apply 因 provider #7886 行为误删已有备份。
