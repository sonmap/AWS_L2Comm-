"""AWS region inventory -> S3 (JSON Lines) -> Glue table -> queryable by Athena.

GCP 원본(app/main.py)의 등가 구현:
  compute_v1.RegionsClient().list()   -> ec2.describe_regions()
  bigquery load_table_from_json       -> S3 PutObject + Glue CreateTable/UpdateTable
  WRITE_TRUNCATE                      -> S3 prefix 삭제 후 재적재
  service_account.Credentials         -> AWS_SHARED_CREDENTIALS_FILE (.oefj)

인증은 GCP 원본과 동일하게 마운트된 키 파일을 명시적으로 읽습니다.
Pod Identity 로 대체 인증하지 않습니다. 키 파일이 없으면 실패합니다.
"""

import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

REGION = os.getenv("AWS_DEFAULT_REGION", "ap-northeast-2")
DATA_BUCKET = os.getenv("DATA_BUCKET", "")
TARGET_DATABASE = os.getenv("TARGET_DATABASE", "dlk_sample")
TARGET_TABLE = os.getenv("TARGET_TABLE", "aws_region_inventory")

# GCP 의 SA_KEY_PATH=/home/jupyter/.oefj 와 같은 경로 계약을 유지합니다.
# 내용만 GCP 서비스 계정 JSON -> AWS 공유 자격증명(INI) 으로 바뀝니다.
SA_KEY_PATH = os.getenv("SA_KEY_PATH", "/home/jupyter/.oefj")
SA_KEY_PROFILE = os.getenv("SA_KEY_PROFILE", "l2comm")

S3_PREFIX = f"{TARGET_DATABASE}/{TARGET_TABLE}"


def load_key_session() -> boto3.Session:
    """마운트된 .oefj 를 AWS 공유 자격증명 파일로 읽어 세션을 만듭니다."""
    if not os.path.isfile(SA_KEY_PATH):
        raise FileNotFoundError(f"Credential file missing: {SA_KEY_PATH}")

    # boto3 는 환경변수로 지정된 공유 자격증명 파일을 읽습니다.
    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = SA_KEY_PATH
    return boto3.Session(profile_name=SA_KEY_PROFILE, region_name=REGION)


def fetch_aws_regions(session: boto3.Session) -> list[dict]:
    ec2 = session.client("ec2")
    loaded_at = datetime.now(timezone.utc).isoformat()
    rows = []

    for region in ec2.describe_regions(AllRegions=True)["Regions"]:
        name = region["RegionName"]
        try:
            zones = [
                z["ZoneName"]
                for z in session.client("ec2", region_name=name)
                .describe_availability_zones()["AvailabilityZones"]
            ]
        except ClientError:
            # 옵트인하지 않은 리전은 조회할 수 없습니다. 빈 목록으로 둡니다.
            zones = []

        rows.append(
            {
                "region_name": name,
                "status": region.get("OptInStatus", ""),
                "description": region.get("Endpoint", ""),
                "self_link": f"https://{region.get('Endpoint', '')}",
                "zones": zones,
                "loaded_at": loaded_at,
            }
        )

    return rows


def write_to_s3(rows: list[dict], session: boto3.Session) -> str:
    """WRITE_TRUNCATE 등가: prefix 를 비우고 JSON Lines 한 개로 새로 적재."""
    if not DATA_BUCKET:
        raise RuntimeError("DATA_BUCKET 환경변수가 비어 있습니다")

    s3 = session.client("s3")

    existing = s3.list_objects_v2(Bucket=DATA_BUCKET, Prefix=f"{S3_PREFIX}/")
    keys = [{"Key": o["Key"]} for o in existing.get("Contents", [])]
    if keys:
        print(f"Truncating {len(keys)} existing object(s) under s3://{DATA_BUCKET}/{S3_PREFIX}/")
        s3.delete_objects(Bucket=DATA_BUCKET, Delete={"Objects": keys})

    body = "\n".join(json.dumps(r, ensure_ascii=False) for r in rows).encode("utf-8")
    key = f"{S3_PREFIX}/data.json"
    s3.put_object(Bucket=DATA_BUCKET, Key=key, Body=body, ContentType="application/json")

    location = f"s3://{DATA_BUCKET}/{S3_PREFIX}/"
    print(f"Loaded {len(rows)} AWS regions into {location}")
    return location


def register_glue_table(location: str, session: boto3.Session) -> None:
    """BigQuery 스키마 선언의 등가. Glue 외부 테이블로 등록합니다."""
    glue = session.client("glue")

    table_input = {
        "Name": TARGET_TABLE,
        "TableType": "EXTERNAL_TABLE",
        "Parameters": {"classification": "json", "EXTERNAL": "TRUE"},
        "StorageDescriptor": {
            "Columns": [
                {"Name": "region_name", "Type": "string"},
                {"Name": "status", "Type": "string"},
                {"Name": "description", "Type": "string"},
                {"Name": "self_link", "Type": "string"},
                {"Name": "zones", "Type": "array<string>"},
                {"Name": "loaded_at", "Type": "string"},
            ],
            "Location": location,
            "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
            "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
            "SerdeInfo": {
                "SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe",
                "Parameters": {"ignore.malformed.json": "true"},
            },
        },
    }

    try:
        glue.create_table(DatabaseName=TARGET_DATABASE, TableInput=table_input)
        print(f"Created Glue table: {TARGET_DATABASE}.{TARGET_TABLE}")
    except glue.exceptions.AlreadyExistsException:
        glue.update_table(DatabaseName=TARGET_DATABASE, TableInput=table_input)
        print(f"Updated Glue table: {TARGET_DATABASE}.{TARGET_TABLE}")


def main() -> None:
    session = load_key_session()
    rows = fetch_aws_regions(session)
    if not rows:
        raise RuntimeError("No AWS region data returned")
    location = write_to_s3(rows, session)
    register_glue_table(location, session)
    print(f"Completed: {TARGET_DATABASE}.{TARGET_TABLE}, rows={len(rows)}")


if __name__ == "__main__":
    main()
