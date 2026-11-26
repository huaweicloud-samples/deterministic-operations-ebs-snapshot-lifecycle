# -*- coding: utf-8 -*-
"""
分层协调函数（核心差异补偿）

背景：
  备份策略按多标签 AND 规则匹配；华为云 CBR 存储库 bind_rules 为
  “多标签 OR”匹配（最多 5 个标签）。为使三档备份策略精确生效，本函数按原始三标签
  AND 规则为每个 EVS 云硬盘派生唯一的 BackupTier 标签（critical/standard/dev），
  再由 CBR 存储库 bind_rules={BackupTier=<tier>} 精确关联。

逻辑：
  - prod + critical + BackupEnabled=true        -> critical
  - prod + standard + BackupEnabled=true        -> standard
  - dev  + BackupEnabled=true                    -> dev
  - 其它                                          -> 不标（不进入任何备份档）

每小时运行一次，及时为新建/改标签的云硬盘打标或修正。

运行期凭证由 FunctionGraph 委托注入：通过 handler 的 context 参数获取
  context.getSecurityAccessKey() / getSecuritySecretKey() / getSecurityToken()
（平台同时以 HWC_ACCESS_KEY / HWC_SECRET_ACCESS_KEY / HWC_SECURITY_TOKEN 环境变量回退）。
代码中不出现真实 AK/SK。
"""

import json
import os

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.exceptions import exceptions

from huaweicloudsdkevs.v2 import (
    EvsClient,
    ListVolumesRequest,
    BatchCreateVolumeTagsRequest,
    BatchCreateVolumeTagsRequestBody,
    Tag,
)
from huaweicloudsdkevs.v2.region.evs_region import EvsRegion


def get_credentials(context):
    """从 FunctionGraph 委托注入的 context 获取临时凭证，回退到 HWC_* 环境变量。"""
    ak = sk = token = None
    if context is not None:
        try:
            ak = context.getSecurityAccessKey()
            sk = context.getSecuritySecretKey()
            token = context.getSecurityToken()
        except Exception as e:
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
    return BasicCredentials(ak, sk, project_id).with_security_token(token)


REGION = os.environ.get("HW_REGION", "cn-north-4")
TAG_KEY = "BackupTier"


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


def compute_tier(tags):
    """依据原始三标签 AND 规则计算应归属的备份档位。"""
    env = tags.get("Environment")
    dc = tags.get("DataClassification")
    be = tags.get("BackupEnabled")
    if env == "prod" and dc == "critical" and be == "true":
        return "critical"
    if env == "prod" and dc == "standard" and be == "true":
        return "standard"
    if env == "dev" and be == "true":
        return "dev"
    return None


def set_tag(evs_client, volume_id, key, value, action):
    """对云硬盘创建/删除单个标签。"""
    request = BatchCreateVolumeTagsRequest()
    request.volume_id = volume_id
    request.body = BatchCreateVolumeTagsRequestBody(
        action=action, tags=[Tag(key=key, value=value)]
    )
    evs_client.batch_create_volume_tags(request)


def handler(event, context):
    print("开始分层标签协调 ...")
    credentials = get_credentials(context)
    evs_client = (
        EvsClient.new_builder()
        .with_credentials(credentials)
        .with_region(EvsRegion.value_of(REGION))
        .build()
    )

    changed = []
    unchanged = 0
    errors = []

    try:
        response = evs_client.list_volumes(ListVolumesRequest())
        volumes = getattr(response, "volumes", []) or []
    except exceptions.ClientRequestException as e:
        print(f"列出云硬盘失败: {e.status_code} {e.error_code} {e.error_msg}")
        return {"statusCode": 500, "body": {"error": str(e.error_msg)}}

    for vol in volumes:
        volume_id = getattr(vol, "id", None)
        tags = parse_tags(getattr(vol, "tags", []) or [])
        computed = compute_tier(tags)
        current = tags.get(TAG_KEY)

        if computed == current:
            unchanged += 1
            continue

        try:
            if current is not None:
                # 先删除旧档位标签（更新场景）
                set_tag(evs_client, volume_id, TAG_KEY, current, "delete")
            if computed is not None:
                set_tag(evs_client, volume_id, TAG_KEY, computed, "create")
            changed.append(
                {
                    "volume_id": volume_id,
                    "name": getattr(vol, "name", "Unknown"),
                    "from": current,
                    "to": computed,
                }
            )
            print(f"云硬盘 {volume_id} 档位标签 {current} -> {computed}")
        except exceptions.ClientRequestException as e:
            errors.append(
                {
                    "volume_id": volume_id,
                    "error": f"{e.status_code} {e.error_code} {e.error_msg}",
                }
            )
            print(f"打标失败 {volume_id}: {e.error_code} {e.error_msg}")

    summary = {
        "timestamp": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        ).isoformat(),
        "total_volumes": len(volumes),
        "unchanged": unchanged,
        "changed": len(changed),
        "errors": len(errors),
        "changes": changed,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False, default=str))
    return {"statusCode": 200, "body": summary}
