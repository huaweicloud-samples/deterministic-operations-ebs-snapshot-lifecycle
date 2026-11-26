# -*- coding: utf-8 -*-
"""
EVS 云硬盘快照完整性/新鲜度校验函数

能力：
  - 遍历所有 BackupEnabled=true 的 EVS 云硬盘
  - 通过 CBR 查询其最新一次可用备份，按 DataClassification 判定新鲜度阈值
      critical -> 2 天；其余 -> 8 天
  - 发现缺失或过期备份时，通过 SMN 主题发送告警

运行期凭证由 FunctionGraph 委托（agency）注入，通过 handler 的 context 参数获取：
  context.getSecurityAccessKey() / getSecuritySecretKey() / getSecurityToken()
（平台同时会以 HWC_ACCESS_KEY / HWC_SECRET_ACCESS_KEY / HWC_SECURITY_TOKEN 形式
 注入环境变量，作为回退）。代码中不出现任何真实 AK/SK。
"""

import json
import os
from datetime import datetime, timezone

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.exceptions import exceptions

from huaweicloudsdkcbr.v1 import CbrClient, ListBackupsRequest
from huaweicloudsdkcbr.v1.region.cbr_region import CbrRegion

from huaweicloudsdkevs.v2 import EvsClient, ListVolumesRequest
from huaweicloudsdkevs.v2.region.evs_region import EvsRegion

from huaweicloudsdksmn.v2 import SmnClient, PublishMessageRequest, PublishMessageRequestBody
from huaweicloudsdksmn.v2.region.smn_region import SmnRegion


def get_credentials(context):
    """从 FunctionGraph 委托注入的 context 获取临时凭证。

    首选 context 方法；若 context 不可用（如未配置函数执行委托），
    回退到平台注入的 HWC_* 环境变量。
    """
    ak = sk = token = None
    if context is not None:
        try:
            ak = context.getSecurityAccessKey()
            sk = context.getSecuritySecretKey()
            token = context.getSecurityToken()
        except Exception as e:  # 某些运行时在未配置执行委托时抛异常
            print(f"通过 context 获取凭证失败，尝试环境变量回退: {e}")

    if not ak or not sk:
        ak = os.environ.get("HWC_ACCESS_KEY")
        sk = os.environ.get("HWC_SECRET_ACCESS_KEY")
        token = os.environ.get("HWC_SECURITY_TOKEN") or None

    project_id = os.environ.get("HW_PROJECT_ID")
    if not ak or not sk:
        raise RuntimeError(
            "缺少访问凭证：请确认函数已绑定 FunctionGraph 委托（建议同时开启"
            "“函数执行委托”），否则 context 无法提供临时 AK/SK/Token。"
        )
    # 临时凭证必须携带 security_token
    return BasicCredentials(ak, sk, project_id).with_security_token(token)


def build_clients(credentials):
    cbr = (
        CbrClient.new_builder()
        .with_credentials(credentials)
        .with_region(CbrRegion.value_of(REGION))
        .build()
    )
    evs = (
        EvsClient.new_builder()
        .with_credentials(credentials)
        .with_region(EvsRegion.value_of(REGION))
        .build()
    )
    smn = (
        SmnClient.new_builder()
        .with_credentials(credentials)
        .with_region(SmnRegion.value_of(REGION))
        .build()
    )
    return cbr, evs, smn


REGION = os.environ.get("HW_REGION", "cn-north-4")


def _parse_ts(value):
    """将 CBR 备份 created_at 解析为带时区的 datetime；解析失败返回最小时间。
    兼容两种 SDK 反序列化结果：字符串 或 已是 datetime 对象。"""
    if value is None:
        return datetime.min.replace(tzinfo=timezone.utc)
    if isinstance(value, datetime):
        return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)
    s = str(value).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def parse_tags(tags_raw):
    """兼容 EVS list_volumes 的标签格式：
    dict({"key": "value"}) / list[dict] / list[str]("key=value") / list[Tag]。"""
    if isinstance(tags_raw, dict):
        return dict(tags_raw)
    tags = {}
    for t in tags_raw or []:
        if isinstance(t, dict):
            tags.update(t)
        elif isinstance(t, str) and "=" in t:
            k, v = t.split("=", 1)
            tags[k] = v
        elif hasattr(t, "key") and hasattr(t, "value"):
            tags[t.key] = t.value
    return tags


def get_backup_eligible_volumes(evs_client):
    """返回所有 BackupEnabled=true 的 EVS 云硬盘（含标签）。"""
    result = []
    try:
        response = evs_client.list_volumes(ListVolumesRequest())
        for vol in getattr(response, "volumes", []) or []:
            tags = parse_tags(getattr(vol, "tags", []) or [])
            if tags.get("BackupEnabled") == "true":
                result.append(
                    {
                        "id": getattr(vol, "id", None),
                        "name": getattr(vol, "name", "Unknown"),
                        "tags": tags,
                    }
                )
    except exceptions.ClientRequestException as e:
        print(f"列出云硬盘失败: {e.status_code} {e.error_code} {e.error_msg}")
    return result


def get_latest_backup(cbr_client, volume_id):
    """返回该云硬盘最新一次 available 状态的 CBR 备份对象。"""
    request = ListBackupsRequest()
    request.resource_id = volume_id
    request.limit = 100
    try:
        response = cbr_client.list_backups(request)
        backups = getattr(response, "backups", []) or []
        available = [
            b for b in backups if getattr(b, "status", None) == "available"
        ]
        if not available:
            return None
        return max(available, key=lambda b: _parse_ts(getattr(b, "created_at", None)))
    except exceptions.ClientRequestException as e:
        print(
            f"查询备份失败 volume={volume_id}: {e.status_code} {e.error_code} {e.error_msg}"
        )
        return None


def analyze(volumes, cbr_client, critical_max, standard_max):
    """核对每个卷的备份新鲜度，返回缺失/过期列表与统计。"""
    missing = []
    for vol in volumes:
        tags = vol["tags"]
        classification = tags.get("DataClassification", "standard")
        max_age = critical_max if classification == "critical" else standard_max

        latest = get_latest_backup(cbr_client, vol["id"])
        if latest is None:
            missing.append(
                {
                    "volume_id": vol["id"],
                    "volume_name": vol["name"],
                    "environment": tags.get("Environment", "Unknown"),
                    "data_classification": classification,
                    "reason": "未找到任何 CBR 备份",
                }
            )
            continue

        age_days = (datetime.now(timezone.utc) - _parse_ts(
            getattr(latest, "created_at", None)
        )).days
        if age_days > max_age:
            missing.append(
                {
                    "volume_id": vol["id"],
                    "volume_name": vol["name"],
                    "environment": tags.get("Environment", "Unknown"),
                    "data_classification": classification,
                    "reason": f"最新备份已 {age_days} 天，阈值 {max_age} 天",
                    "latest_backup_age_days": age_days,
                }
            )
    return missing


def build_report(volumes, missing):
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "monitored_volumes": len(volumes),
            "volumes_with_missing_backups": len(missing),
        },
        "missing_backups": missing,
        "health_status": "HEALTHY" if not missing else "WARNING",
        "recommendations": [],
    }
    if missing:
        report["recommendations"].append(
            f"{len(missing)} 个云硬盘存在缺失或过期备份，请检查 CBR 策略关联与云硬盘 BackupTier 标签。"
        )
    else:
        report["recommendations"].append("所有备份策略运行正常。")
    return report


def send_notification(smn_client, topic_urn, report):
    try:
        body = PublishMessageRequestBody(
            subject=f"EVS 快照校验 - {report['health_status']}",
            message=(
                "EVS 快照校验报告\n"
                f"生成时间: {report['timestamp']}\n\n"
                f"监控云硬盘数: {report['summary']['monitored_volumes']}\n"
                f"备份缺口数: {report['summary']['volumes_with_missing_backups']}\n"
                f"健康状态: {report['health_status']}\n\n"
                "建议:\n"
                + "\n".join(f"- {r}" for r in report["recommendations"])
                + "\n\n完整日志见 FunctionGraph LTS 日志流。"
            ),
        )
        request = PublishMessageRequest()
        request.topic_urn = topic_urn
        request.body = body
        smn_client.publish_message(request)
        print(f"告警已发送至 {topic_urn}")
    except exceptions.ClientRequestException as e:
        print(f"发送告警失败: {e.status_code} {e.error_code} {e.error_msg}")


def handler(event, context):
    print("开始 EVS 快照校验 ...")
    credentials = get_credentials(context)
    cbr_client, evs_client, smn_client = build_clients(credentials)

    critical_max = int(os.environ.get("CRITICAL_MAX_AGE_DAYS", "2"))
    standard_max = int(os.environ.get("STANDARD_MAX_AGE_DAYS", "8"))

    volumes = get_backup_eligible_volumes(evs_client)
    missing = analyze(volumes, cbr_client, critical_max, standard_max)
    report = build_report(volumes, missing)

    print(json.dumps(report, indent=2, ensure_ascii=False, default=str))

    topic_urn = os.environ.get("SMN_TOPIC_URN")
    if topic_urn and report["health_status"] != "HEALTHY":
        send_notification(smn_client, topic_urn, report)

    return {"statusCode": 200, "body": report}
