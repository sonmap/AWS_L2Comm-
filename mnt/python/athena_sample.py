#!/usr/bin/env python3
"""GCP 원본 mnt/python/bq_sample.py 의 등가 구현. 기존 테이블 조회 샘플."""
import os
import time

import boto3

REGION = os.getenv("AWS_DEFAULT_REGION", "ap-northeast-2")
WORKGROUP = os.getenv("ATHENA_WORKGROUP", "wg-l2comm")
DATABASE = os.getenv("TARGET_DATABASE", "dlk_sample")
TABLE = os.getenv("ATHENA_SAMPLE_TABLE", "aws_region_inventory")
LIMIT = int(os.getenv("ATHENA_SAMPLE_LIMIT", "10"))
SA_KEY_PATH = os.getenv("SA_KEY_PATH", "/home/jupyter/.oefj")
SA_KEY_PROFILE = os.getenv("SA_KEY_PROFILE", "l2comm")


def run_query(athena, sql: str) -> list[list[str]]:
    qid = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": DATABASE},
        WorkGroup=WORKGROUP,
    )["QueryExecutionId"]

    while True:
        status = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        if status["State"] in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)

    if status["State"] != "SUCCEEDED":
        raise RuntimeError(f"Athena query {status['State']}: {status.get('StateChangeReason', '')}")

    out = []
    paginator = athena.get_paginator("get_query_results")
    first = True
    for page in paginator.paginate(QueryExecutionId=qid):
        for row in page["ResultSet"]["Rows"]:
            if first:
                first = False  # header row
                continue
            out.append([c.get("VarCharValue", "") for c in row["Data"]])
    return out


def main() -> None:
    if not os.path.isfile(SA_KEY_PATH):
        raise FileNotFoundError(f"Credential file not found: {SA_KEY_PATH}")

    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = SA_KEY_PATH
    session = boto3.Session(profile_name=SA_KEY_PROFILE, region_name=REGION)

    identity = session.client("sts").get_caller_identity()
    print(f"[INFO] Credential source : {SA_KEY_PATH}")
    print(f"[INFO] Caller identity   : {identity['Arn']}")

    athena = session.client("athena")

    sql = f"""
    SELECT
      region_name,
      status,
      description,
      loaded_at
    FROM "{DATABASE}"."{TABLE}"
    ORDER BY region_name
    LIMIT {LIMIT}
    """

    print(f"[INFO] Athena workgroup  : {WORKGROUP}")
    print(f"[INFO] Sample table      : {DATABASE}.{TABLE}")
    print(f"[INFO] Limit             : {LIMIT}")
    print()

    rows = run_query(athena, sql)

    print(f"[INFO] rows={len(rows)}")
    for row in rows:
        print("\t".join(row))


if __name__ == "__main__":
    main()
