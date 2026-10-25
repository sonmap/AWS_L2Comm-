#!/usr/bin/env python3
"""Minimal check: Pod-mounted .oefj credentials and Athena query execution (no table needed).

GCP 원본 bq_auth_smoke.py 의 등가 구현.
  service_account.Credentials.from_service_account_file -> boto3.Session(profile_name=...)
  bigquery.Client.query("SELECT ...")                   -> athena.start_query_execution
"""
import os
import time

import boto3

region = os.getenv("AWS_DEFAULT_REGION", "ap-northeast-2")
workgroup = os.getenv("ATHENA_WORKGROUP", "wg-l2comm")
database = os.getenv("TARGET_DATABASE", "dlk_sample")
key_path = os.getenv("SA_KEY_PATH", "/home/jupyter/.oefj")
key_profile = os.getenv("SA_KEY_PROFILE", "l2comm")

if not os.path.isfile(key_path):
    raise FileNotFoundError(f"Credential file missing: {key_path}")

os.environ["AWS_SHARED_CREDENTIALS_FILE"] = key_path
session = boto3.Session(profile_name=key_profile, region_name=region)

identity = session.client("sts").get_caller_identity()
print(f"[INFO] Credential source : {key_path} (profile={key_profile})")
print(f"[INFO] Caller identity   : {identity['Arn']}")

athena = session.client("athena")
qid = athena.start_query_execution(
    QueryString="SELECT 'L2COMM' AS program_id, 'SUCCESS' AS result",
    QueryExecutionContext={"Database": database},
    WorkGroup=workgroup,
)["QueryExecutionId"]

while True:
    state = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
    if state["State"] in ("SUCCEEDED", "FAILED", "CANCELLED"):
        break
    time.sleep(1)

if state["State"] != "SUCCEEDED":
    raise RuntimeError(f"Athena query {state['State']}: {state.get('StateChangeReason', '')}")

rows = athena.get_query_results(QueryExecutionId=qid)["ResultSet"]["Rows"]
# rows[0] is the header row.
for row in rows[1:]:
    values = [c.get("VarCharValue", "") for c in row["Data"]]
    print(f"{values[0]}: {values[1]}")
