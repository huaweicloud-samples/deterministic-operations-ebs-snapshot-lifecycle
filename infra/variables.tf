variable "region" {
  description = "华为云区域（如 cn-north-4 北京四、cn-east-3 上海一）"
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "项目名称，作为资源命名前缀"
  type        = string
  default     = "ebs-cbr-automation"
}

variable "alert_email" {
  description = "快照校验告警接收邮箱（用于订阅 SMN 主题）"
  type        = string
  default     = "your-email@example.com"
}

# ---- 规格参数 ----

variable "evs_volume_type" {
  description = "EVS 云硬盘类型（GPSSD 通用型 SSD）"
  type        = string
  default     = "GPSSD"
}

variable "cbr_vault_size_critical" {
  description = "生产关键级 CBR 磁盘存储库容量（GB）"
  type        = number
  default     = 200
}

variable "cbr_vault_size_standard" {
  description = "生产标准级 CBR 磁盘存储库容量（GB）"
  type        = number
  default     = 100
}

variable "cbr_vault_size_dev" {
  description = "开发级 CBR 磁盘存储库容量（GB）"
  type        = number
  default     = 50
}

variable "rms_agency_delegated_service" {
  description = "RMS/配置审计 资源记录器委托所委托的云服务名。官方 RFS 模板使用 op_svc_eps；若 apply 报 'invalid delegated service'，请改用 'rms' 或在控制台创建名为 rms_tracker_agency 的委托"
  type        = string
  default     = "op_svc_eps"
}
