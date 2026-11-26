# 部署前请按需修改以下值（其余规格默认即可，均显式写死）
region        = "cn-north-4"
project_name  = "ebs-cbr-automation"
alert_email   = "your-email@example.com"

# 规格参数
evs_volume_type          = "GPSSD"
cbr_vault_size_critical  = 200
cbr_vault_size_standard  = 100
cbr_vault_size_dev       = 50

# 若 apply 报“invalid delegated service”，将此处改为 "rms" 或在控制台建 rms_tracker_agency 委托
rms_agency_delegated_service = "op_svc_eps"
