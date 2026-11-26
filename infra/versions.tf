terraform {
  required_version = ">= 1.5"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.70"
    }
  }

  backend "local" {
    # 生产环境建议将状态文件存入 OBS（见 docs/deployment-guide.md 的“远程状态”一节）
    path = "terraform.tfstate"
  }
}

# ============================================================================
# Provider 配置
# AK/SK 一律从环境变量读取，不在代码或报告中出现真实凭据
#   export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
#   export HW_SECRET_KEY="<HW_SECRET_KEY>"
#   临时凭证（推荐）：export HW_SECURITY_TOKEN="<TOKEN>"
# ============================================================================
provider "huaweicloud" {
  region = var.region
}
