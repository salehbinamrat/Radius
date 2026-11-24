"""Measure the real session query, without a hardware-dependent CI SLA."""
import json
import os
import re
import statistics
import sys
from pathlib import Path

import psycopg2
from radius_secret_input import load_hex

CANDIDATES = (
    "CREATE INDEX idx_perf_session_recent ON public.radacct "
    "((COALESCE(acctupdatetime,acctstarttime)) DESC,radacctid DESC)",
    "CREATE INDEX idx_perf_session_user_recent ON public.radacct "
    "(username,(COALESCE(acctupdatetime,acctstarttime)) DESC,radacctid DESC)",
)

def seed(cur):
    cur.execute("""
        INSERT INTO app_plans(id,name,upload_kbps,download_kbps)
        VALUES ('11111111-1111-4111-8111-111111111111','performance-fixture',256,1024);
        INSERT INTO app_lab_accounts(username,plan_id)
        SELECT 'lab_'||lpad(to_hex(i),12,'0'),'11111111-1111-4111-8111-111111111111'
        FROM generate_series(0,999) i;
        INSERT INTO radacct(acctsessionid,acctuniqueid,username,nasipaddress,
            acctstarttime,acctupdatetime,acctstoptime,acctinputoctets,acctoutputoctets)
        SELECT 'perf-'||g,md5('performance-'||g),
            'lab_'||lpad(to_hex(CASE WHEN g<=5000 THEN 0 ELSE g%1250 END),12,'0'),
            '10.255.70.21'::inet,
            CASE WHEN g%97=0 THEN NULL ELSE now()-(g/4)*interval '1 second'-interval '1 minute' END,
            CASE WHEN g%97=0 THEN NULL ELSE now()-(g/4)*interval '1 second' END,
            CASE WHEN g%3=0 AND g%97<>0 THEN now()-(g/4)*interval '1 second' ELSE NULL END,
            CASE WHEN g%89=0 THEN -1 ELSE g::bigint*10 END,g::bigint*20
        FROM generate_series(1,100000) g;
        ANALYZE app_lab_accounts;
        ANALYZE radacct;
    """)
    cur.execute("""SELECT count(*),count(*) FILTER (WHERE l.username IS NULL)
        FROM radacct a LEFT JOIN app_lab_accounts l ON l.username=a.username""")
    total,foreign=cur.fetchone()
    assert total==100000 and foreign>10000
    print(f"PERF FIXTURE rows={total} foreign_rows={foreign} registered_accounts=1000",flush=True)

def actual_session_query():
    source=Path("/opt/radius/LabSessionEndpoints.cs").read_text()
    match=re.search(r'const string sql\s*=\s*"""(.*?)"""\s*;',source,re.S)
    if not match:
        raise RuntimeError("Session query source missing")
    return match.group(1).replace("@user","%(user)s").replace("@state","%(state)s")

def indexes(plan):
    result=[]
    if "Index Name" in plan: result.append(plan["Index Name"])
    for child in plan.get("Plans",[]): result.extend(indexes(child))
    return result

def sample(cur,query,params,label,phase):
    cur.execute(query,params)
    rows=cur.fetchall()
    timings=[]
    blocks=[]
    used=set()
    # One warm-up and five measured executions. Timing and buffers refer to
    # PostgreSQL execution, not network/UI latency. No forced planner setting.
    for i in range(6):
        cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "+query,params)
        report=cur.fetchone()[0][0]
        plan=report["Plan"]
        if i:
            timings.append(float(report["Execution Time"]))
            blocks.append(int(plan.get("Shared Hit Blocks",0))+int(plan.get("Shared Read Blocks",0)))
            used.update(indexes(plan))
    metric={"phase":phase,"case":label,"rows":len(rows),
            "median_ms":round(statistics.median(timings),4),
            "max_ms":round(max(timings),4),
            "median_shared_blocks":statistics.median(blocks),"indexes":sorted(used)}
    print("PERF "+json.dumps(metric,sort_keys=True),flush=True)
    return rows

def main():
    if os.environ.get("CI")!="true" or os.environ.get("RADIUS_PERF_TEST_ACK")!="isolated-ci":
        raise RuntimeError("Isolated CI acknowledgement required")
    db=os.environ["MIGRATION_DB_NAME"]
    if not re.fullmatch(r"radius_mig_[a-f0-9]{8}",db):
        raise RuntimeError("Unsafe performance database")
    conn=psycopg2.connect(host="db",dbname=db,user="radius",
                          password=load_hex("DB_PASSWORD"),connect_timeout=5)
    try:
        with conn.cursor() as cur:
            cur.execute("SET LOCAL statement_timeout='60s'")
            cur.execute("SELECT count(*) FROM radacct")
            assert cur.fetchone()==(0,)
            seed(cur)
            query=actual_session_query()
            cases=[(state,{"user":"","state":state},query) for state in ("all","open","closed","stale")]
            cases += [("single-heavy",{"user":"lab_000000000000","state":"all"},query),
                      ("foreign-denied",{"user":"lab_0000000004e1","state":"all"},query),
                      ("usage-heavy",{"user":"lab_000000000000"},"SELECT * FROM app_lab_usage_snapshot(%(user)s)")]
            before={label:sample(cur,q,p,label,"baseline") for label,p,q in cases}
            for label in ("all","open","closed","stale","single-heavy"):
                assert len(before[label])==101,label
                assert all(int(row[0][4:],16)<1000 for row in before[label]),label
            assert before["foreign-denied"]==[]
            assert len(before["usage-heavy"])==1 and before["usage-heavy"][0][2]>5000
            for statement in CANDIDATES: cur.execute(statement)
            cur.execute("ANALYZE radacct")
            for label,p,q in cases:
                after=sample(cur,q,p,label,"candidate")
                assert after==before[label],f"Changed result or order: {label}"
            cur.execute("""SELECT relname,pg_relation_size(oid) FROM pg_class
                WHERE relname IN ('idx_perf_session_recent','idx_perf_session_user_recent') ORDER BY relname""")
            for name,size in cur.fetchall():
                print(f"PERF INDEX {name} bytes={size}",flush=True)
        # Everything, including candidate indexes and data, is rolled back.
        conn.rollback()
        print("PERF exact query results and lab isolation preserved; no production index applied")
    finally:
        conn.close()

if __name__=="__main__":
    try: main()
    except Exception as exc:
        print("Accounting performance fixture failed ("+type(exc).__name__+")",file=sys.stderr)
        # Only assertions contain fixed test-case labels, never row data or passwords.
        if isinstance(exc,AssertionError): print(str(exc),file=sys.stderr)
        if isinstance(exc,psycopg2.Error): print("SQLSTATE "+str(exc.pgcode),file=sys.stderr)
        sys.exit(1)
