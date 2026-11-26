# ============================================================================
# 数据来源：当前项目（用于 OBS 桶名唯一化、SMN/RMS project_id）
# ============================================================================
data "huaweicloud_identity_projects" "current" {
  name = var.region
}

# 说明：EVS 云硬盘支持 KMS 加密，但华为云首次在本区域使用 EVS 加密需控制台授权 EVS 服务(op_svc_evs)访问 KMS（含 KMS grant），
# API/terraform 无法稳定复现，会报 EVS.2264。为交付可用环境，此处暂不加密；
# 启用方法见 docs/deployment-guide.md “EVS 加密（可选）”。

# ============================================================================
# 1. EVS 云硬盘
#    - EVS 云硬盘（GPSSD 通用型 SSD）；保留原始三标签 + 派生 BackupTier 标签
#    - BackupTier 标签供 CBR 存储库 bind_rules 自动关联（见架构适配说明）
# ============================================================================
resource "huaweicloud_evs_volume" "prod_critical_1" {
  name              = "prod-critical-volume-1"
  volume_type       = var.evs_volume_type
  size              = 10
  availability_zone = "${var.region}a"

  tags = {
    Name               = "Prod-Critical-Volume-1"
    Environment        = "prod"
    DataClassification = "critical"
    BackupEnabled      = "true"
    BackupTier         = "critical"
    Project            = var.project_name
  }
}

resource "huaweicloud_evs_volume" "prod_critical_2" {
  name              = "prod-critical-volume-2"
  volume_type       = var.evs_volume_type
  size              = 10
  availability_zone = "${var.region}a"

  tags = {
    Name               = "Prod-Critical-Volume-2"
    Environment        = "prod"
    DataClassification = "critical"
    BackupEnabled      = "true"
    BackupTier         = "critical"
    Project            = var.project_name
  }
}

resource "huaweicloud_evs_volume" "prod_standard" {
  name              = "prod-standard-volume"
  volume_type       = var.evs_volume_type
  size              = 8
  availability_zone = "${var.region}a"

  tags = {
    Name               = "Prod-Standard-Volume"
    Environment        = "prod"
    DataClassification = "standard"
    BackupEnabled      = "true"
    BackupTier         = "standard"
    Project            = var.project_name
  }
}

resource "huaweicloud_evs_volume" "dev_volume" {
  name              = "dev-volume"
  volume_type       = var.evs_volume_type
  size              = 5
  availability_zone = "${var.region}a"

  tags = {
    Name               = "Dev-Volume"
    Environment        = "dev"
    DataClassification = "standard"
    BackupEnabled      = "true"
    BackupTier         = "dev"
    Project            = var.project_name
  }
}

# 不合规卷：故意缺失 Environment / DataClassification / BackupEnabled 标签，
# 既不会被 CBR 存储库关联（无 BackupTier），也会在 RMS required-all-tags 规则下被判不合规。
resource "huaweicloud_evs_volume" "non_compliant" {
  name              = "non-compliant-volume"
  volume_type       = var.evs_volume_type
  size              = 8
  availability_zone = "${var.region}a"

  tags = {
    Name    = "Non-Compliant-Volume"
    Project = var.project_name
  }
}

# ============================================================================
# 2. CBR 存储库（磁盘型，按 BackupTier 自动关联云硬盘）
#    - bind_rules 仅含单个标签 BackupTier=<tier>，实现“精确匹配该标签”的 AND 语义
#      （CBR 多标签 bind_rules 为 OR 关系；本实践通过“派生单标签 + 协调函数”
#       方案实现多条件分层备份）
#    - auto_bind=true：新建时即按 bind_rules 自动关联 EVS 云硬盘
#    - disk 类型只能 crash_consistent
# ============================================================================
resource "huaweicloud_cbr_vault" "critical" {
  name              = "${var.project_name}-vault-critical"
  type              = "disk"
  protection_type   = "backup"
  size              = var.cbr_vault_size_critical
  consistent_level  = "crash_consistent"
  auto_bind         = true
  bind_rules        = {
    BackupTier = "critical"
  }

  # 显式绑定现有 critical 卷：auto_bind 只在下一个备份周期才扫描，无法立即生效。
  # 由于 provider 在更新 resources 时可能删除已有备份（#7886），后续对此块做 ignore_changes。
  resources {
    includes = [
      huaweicloud_evs_volume.prod_critical_1.id,
      huaweicloud_evs_volume.prod_critical_2.id,
    ]
  }

  policy {
    id = huaweicloud_cbr_policy.critical.id
  }

  tags = {
    Project    = var.project_name
    BackupTier = "critical"
  }

  lifecycle {
    ignore_changes = [resources]
  }
}

resource "huaweicloud_cbr_vault" "standard" {
  name              = "${var.project_name}-vault-standard"
  type              = "disk"
  protection_type   = "backup"
  size              = var.cbr_vault_size_standard
  consistent_level  = "crash_consistent"
  auto_bind         = true
  bind_rules        = {
    BackupTier = "standard"
  }

  resources {
    includes = [
      huaweicloud_evs_volume.prod_standard.id,
    ]
  }

  policy {
    id = huaweicloud_cbr_policy.standard.id
  }

  tags = {
    Project    = var.project_name
    BackupTier = "standard"
  }

  lifecycle {
    ignore_changes = [resources]
  }
}

resource "huaweicloud_cbr_vault" "dev" {
  name              = "${var.project_name}-vault-dev"
  type              = "disk"
  protection_type   = "backup"
  size              = var.cbr_vault_size_dev
  consistent_level  = "crash_consistent"
  auto_bind         = true
  bind_rules        = {
    BackupTier = "dev"
  }

  resources {
    includes = [
      huaweicloud_evs_volume.dev_volume.id,
    ]
  }

  policy {
    id = huaweicloud_cbr_policy.dev.id
  }

  tags = {
    Project    = var.project_name
    BackupTier = "dev"
  }

  lifecycle {
    ignore_changes = [resources]
  }
}

# ============================================================================
# 3. CBR 备份策略（三档差异化保留）
#    执行时间 execution_times 为 UTC，分钟必须为 00
#    保留策略用 backup_quantity（按份数），范围 2–99,999
# ============================================================================
resource "huaweicloud_cbr_policy" "critical" {
  name             = "${var.project_name}-policy-critical"
  type             = "backup"
  enabled          = true
  backup_quantity  = 30 # 每日 @03:00 UTC，保留 30 份（约 30 天）

  backup_cycle {
    days            = "MO,TU,WE,TH,FR,SA,SU"
    execution_times = ["03:00"]
  }
}

resource "huaweicloud_cbr_policy" "standard" {
  name             = "${var.project_name}-policy-standard"
  type             = "backup"
  enabled          = true
  backup_quantity  = 8 # 每周日 @02:00 UTC，保留 8 份（约 8 周）

  backup_cycle {
    days            = "SU"
    execution_times = ["02:00"]
  }
}

resource "huaweicloud_cbr_policy" "dev" {
  name             = "${var.project_name}-policy-dev"
  type             = "backup"
  enabled          = true
  backup_quantity  = 7 # 每日 @01:00 UTC，保留 7 份（约 7 天）

  backup_cycle {
    days            = "MO,TU,WE,TH,FR,SA,SU"
    execution_times = ["01:00"]
  }
}

# ============================================================================
# 4. OBS 桶（承接配置审计的资源变更快照与通知）
#    桶名全局唯一且须 DNS 合规（不含下划线）——这里用连字符并拼接项目 ID
# ============================================================================
resource "huaweicloud_obs_bucket" "config" {
  bucket        = "${replace(var.project_name, "_", "-")}-config-${data.huaweicloud_identity_projects.current.projects[0].id}"
  acl           = "private"
  force_destroy = true
  versioning    = true

  tags = {
    Project = var.project_name
  }
}

# ============================================================================
# 5. SMN 主题（承接校验告警 + 配置审计通知）
# ============================================================================
resource "huaweicloud_smn_topic" "alerts" {
  name         = "${replace(var.project_name, "_", "-")}-alerts"
  display_name = "${var.project_name} alerts"
}

resource "huaweicloud_smn_subscription" "alert_email" {
  topic_urn = huaweicloud_smn_topic.alerts.topic_urn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ============================================================================
# 6. IAM 委托
# ============================================================================
# 6.1 FunctionGraph 委托：函数运行期以此委托的临时凭证调用 CBR/EVS/SMN
resource "huaweicloud_identity_agency" "functiongraph" {
  name                  = "${var.project_name}-fgs-agency"
  description           = "Agency for FunctionGraph to call CBR/EVS/SMN"
  duration              = "FOREVER"
  delegated_service_name = "op_svc_cff" # FunctionGraph 的委托服务名（非 op_svc_functiongraph）

  project_role {
    project = var.region
    roles   = ["CBR FullAccess", "EVS FullAccess", "SMN FullAccess"]
  }
}

# 6.2 配置审计（RMS）委托：记录器写 OBS、发 SMN 通知所需权限
resource "huaweicloud_identity_agency" "rms" {
  name                   = "${var.project_name}-rms-agency"
  description            = "Agency for Config/RMS resource recorder (OBS + SMN)"
  duration               = "FOREVER"
  delegated_service_name = var.rms_agency_delegated_service

  all_resources_roles = ["SMN Administrator", "OBS Administrator", "KMS Administrator"]
}

# 6.3 注：EVS 加密所需的 op_svc_evs KMS 授权委托已不再在此创建（见上方“说明”）。

# ============================================================================
# 7. 配置审计 RMS：资源记录器 + 必需标签合规规则
# ============================================================================
resource "huaweicloud_rms_resource_recorder" "main" {
  agency_name = huaweicloud_identity_agency.rms.name

  selector {
    all_supported  = false
    resource_types = ["evs.volumes"]
  }

  obs_channel {
    bucket = huaweicloud_obs_bucket.config.bucket
    region = var.region
  }

  smn_channel {
    region     = var.region
    topic_urn  = huaweicloud_smn_topic.alerts.topic_urn
    project_id = data.huaweicloud_identity_projects.current.projects[0].id
  }

  depends_on = [huaweicloud_identity_agency.rms]
}

data "huaweicloud_rms_policy_definitions" "required_all_tags" {
  name = "required-all-tags"
}

resource "huaweicloud_rms_policy_assignment" "required_tags" {
  name                = "${var.project_name}-required-tags"
  description         = "EVS 云硬盘必须同时包含 Environment / DataClassification / BackupEnabled 三个标签"
  policy_definition_id = try(data.huaweicloud_rms_policy_definitions.required_all_tags.definitions[0].id, "")
  status              = "Enabled"

  parameters = {
    # required-all-tags 规则参数：TagKeys=需包含的标签键；TagValues=允许的标签值列表，空列表表示任意值
    TagKeys   = jsonencode(["Environment", "DataClassification", "BackupEnabled"])
    TagValues = jsonencode([])
  }

  policy_filter {
    region            = var.region
    resource_provider = "evs"
    resource_type     = "volumes"
  }

  # 资源记录器刚建好时需等待其变为 enabled，否则报 RMS.00010091 "Resource recorder disabled"
  depends_on = [huaweicloud_rms_resource_recorder.main]
}

# ============================================================================
# 输出
# ============================================================================
output "cbr_vault_ids" {
  description = "三个分层 CBR 存储库 ID"
  value = {
    critical = huaweicloud_cbr_vault.critical.id
    standard = huaweicloud_cbr_vault.standard.id
    dev      = huaweicloud_cbr_vault.dev.id
  }
}

output "cbr_policy_ids" {
  description = "三个分层 CBR 备份策略 ID"
  value = {
    critical = huaweicloud_cbr_policy.critical.id
    standard = huaweicloud_cbr_policy.standard.id
    dev      = huaweicloud_cbr_policy.dev.id
  }
}

output "evs_volume_ids" {
  description = "创建的 EVS 云硬盘 ID"
  value = {
    prod_critical_1 = huaweicloud_evs_volume.prod_critical_1.id
    prod_critical_2 = huaweicloud_evs_volume.prod_critical_2.id
    prod_standard   = huaweicloud_evs_volume.prod_standard.id
    dev             = huaweicloud_evs_volume.dev_volume.id
    non_compliant   = huaweicloud_evs_volume.non_compliant.id
  }
}

output "obs_bucket_name" {
  description = "配置审计投递用 OBS 桶名"
  value       = huaweicloud_obs_bucket.config.bucket
}

output "smn_topic_urn" {
  description = "告警 SMN 主题 URN"
  value       = huaweicloud_smn_topic.alerts.topic_urn
}

output "rms_policy_assignment_id" {
  description = "必需标签合规规则分配 ID"
  value       = huaweicloud_rms_policy_assignment.required_tags.id
}
