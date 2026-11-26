# ============================================================================
# FunctionGraph 函数 + TIMER 触发器
#   - 校验函数：每日 06:00 UTC 核对 EVS 云硬盘是否有新鲜且完整的 CBR 备份
#   - 协调函数：每小时按原始三标签 AND 规则派生 BackupTier 标签（核心差异补偿）
# 运行期凭证由 functiongraph 委托注入环境变量（HUAWEI_ACCESS_KEY/SECRET/TOKEN），
# 代码中与 user_data 中均不出现任何真实 AK/SK。
# ============================================================================

# ---- LTS：FunctionGraph 默认日志组/流由平台自动创建，此处不再显式绑定，
#      以避免 FSS.1212（显式绑定偶发“group or stream not existed”）。
#      函数运行日志将写入 FunctionGraph 自动创建的默认 LTS 日志组。

# ---- 函数部署包：华为云 FunctionGraph 运行环境不含 huaweicloudsdk* 包，
#      因此把 index.py 连同依赖打包成 zip，上传到 OBS，函数通过 obs 方式引用。
resource "huaweicloud_obs_bucket_object" "snapshot_verification_pkg" {
  bucket = huaweicloud_obs_bucket.config.bucket
  key    = "function-packages/snapshot_verification.zip"
  source = "${path.module}/../src/functions/snapshot_verification/snapshot_verification.zip"
  acl    = "public-read"
  etag   = filemd5("${path.module}/../src/functions/snapshot_verification/snapshot_verification.zip")
}

resource "huaweicloud_obs_bucket_object" "tier_coordinator_pkg" {
  bucket = huaweicloud_obs_bucket.config.bucket
  key    = "function-packages/tier_coordinator.zip"
  source = "${path.module}/../src/functions/tier_coordinator/tier_coordinator.zip"
  acl    = "public-read"
  etag   = filemd5("${path.module}/../src/functions/tier_coordinator/tier_coordinator.zip")
}

# ============================================================================
# 校验函数：快照完整性/新鲜度核对
# ============================================================================
resource "huaweicloud_fgs_function" "snapshot_verification" {
  name          = "${var.project_name}-snapshot-verification"
  app           = "default"
  agency        = huaweicloud_identity_agency.functiongraph.name
  handler       = "index.handler"
  runtime       = "Python3.9"
  memory_size   = 256
  timeout       = 300
  code_type     = "obs"
  code_url      = "https://${huaweicloud_obs_bucket.config.bucket}.obs.${var.region}.myhuaweicloud.com/${huaweicloud_obs_bucket_object.snapshot_verification_pkg.key}"
  code_filename = "snapshot_verification.zip"
  description   = "校验 EVS 云硬盘是否有新鲜且完整的 CBR 备份，缺口通过 SMN 告警"

  depends_on = [huaweicloud_obs_bucket_object.snapshot_verification_pkg]

  user_data = jsonencode({
    SMN_TOPIC_URN         = huaweicloud_smn_topic.alerts.topic_urn
    HW_REGION             = var.region
    HW_PROJECT_ID         = data.huaweicloud_identity_projects.current.projects[0].id
    CRITICAL_MAX_AGE_DAYS = "2"
    STANDARD_MAX_AGE_DAYS = "8"
  })
}

# 每日 06:00 UTC 触发（cron: 0 0 6 * * *）
resource "huaweicloud_fgs_function_trigger" "verification_daily" {
  function_urn = huaweicloud_fgs_function.snapshot_verification.urn
  type         = "TIMER"
  status       = "ACTIVE"
  event_data   = jsonencode({
    name          = "daily-verification"
    schedule_type = "Cron"
    schedule      = "0 0 6 * * *"
  })

  # TIMER 触发器一旦 ACTIVE，API 拒绝元数据更新；忽略 event_data/status 避免 provider 反复尝试 PUT 报 FSS.1153
  lifecycle {
    ignore_changes = [event_data, status]
  }
}

# ============================================================================
# 协调函数：派生 BackupTier 标签（核心差异补偿）
# ============================================================================
resource "huaweicloud_fgs_function" "tier_coordinator" {
  name          = "${var.project_name}-tier-coordinator"
  app           = "default"
  agency        = huaweicloud_identity_agency.functiongraph.name
  handler       = "index.handler"
  runtime       = "Python3.9"
  memory_size   = 256
  timeout       = 120
  code_type     = "obs"
  code_url      = "https://${huaweicloud_obs_bucket.config.bucket}.obs.${var.region}.myhuaweicloud.com/${huaweicloud_obs_bucket_object.tier_coordinator_pkg.key}"
  code_filename = "tier_coordinator.zip"
  description   = "按原始三标签 AND 规则为 EVS 云硬盘派生 BackupTier 标签，供 CBR 存储库自动关联"

  depends_on = [huaweicloud_obs_bucket_object.tier_coordinator_pkg]

  user_data = jsonencode({
    HW_REGION     = var.region
    HW_PROJECT_ID = data.huaweicloud_identity_projects.current.projects[0].id
  })
}

# 每小时触发一次，及时为新创建的 EVS 云硬盘打标
resource "huaweicloud_fgs_function_trigger" "coordinator_hourly" {
  function_urn = huaweicloud_fgs_function.tier_coordinator.urn
  type         = "TIMER"
  status       = "ACTIVE"
  event_data   = jsonencode({
    name          = "hourly-coordinator"
    schedule_type = "Cron"
    schedule      = "0 0 * * * *"
  })

  # TIMER 触发器一旦 ACTIVE，API 拒绝元数据更新；忽略 event_data/status 避免 provider 反复尝试 PUT 报 FSS.1153
  lifecycle {
    ignore_changes = [event_data, status]
  }
}

# ============================================================================
# 输出
# ============================================================================
output "function_verification_urn" {
  description = "快照校验函数 URN"
  value       = huaweicloud_fgs_function.snapshot_verification.urn
}

output "function_coordinator_urn" {
  description = "分层协调函数 URN"
  value       = huaweicloud_fgs_function.tier_coordinator.urn
}
