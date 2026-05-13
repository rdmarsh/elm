# Bug Report: `numOfHosts` and `numOfInstances` always zero in GET /setting/collector/groups

## Summary

`GET /setting/collector/groups` (getCollectorGroupList) returns `numOfHosts: 0` and
`numOfInstances: 0` for every group in the response, regardless of how many hosts or
instances the group actually has. The per-group endpoint `GET /setting/collector/groups/{id}`
(getCollectorGroupById) returns the correct values for the same group.

Additionally, `highestPriorityCollectorStatus.status` disagrees between the two endpoints
for the same group.

## Steps to reproduce

1. Call `GET /setting/collector/groups` — observe `numOfHosts: 0` and `numOfInstances: 0`
   for all groups in the items array.
2. Take one of those group IDs and call `GET /setting/collector/groups/{id}` — observe
   `numOfHosts` and `numOfInstances` now return the correct non-zero values.

See the demo script below for a self-contained reproduction.

## Expected behaviour

`GET /setting/collector/groups` should return the same `numOfHosts` and `numOfInstances`
values as `GET /setting/collector/groups/{id}` for the same group.

## Actual behaviour

| Field | getCollectorGroupList | getCollectorGroupById |
|---|---|---|
| `numOfHosts` | **0** (always) | **6** (correct) |
| `numOfInstances` | **0** (always) | **1225** (correct, when autoBalance is on) |
| `highestPriorityCollectorStatus.status` | **1** | **0** |

`numOfInstances` via the list endpoint is 0 regardless of whether `autoBalance` is enabled
or disabled. Via the ById endpoint it reflects the load-balanced instance count when
`autoBalance` is on, and is 0 when `autoBalance` is off (expected behaviour for ById).

## Environment

- API version: v3
- Account: acme (sandbox)
- Collector group tested: id=64

## References

- [getCollectorGroupList](https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/#/Collector%20Groups/getCollectorGroupList)
- [getCollectorGroupById](https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/#/Collector%20Groups/getCollectorGroupById)

---

## Demo script

Requires Python 3 and the `requests` library. Set `ACCESS_ID`, `ACCESS_KEY`, and
`ACCOUNT_NAME` before running.

```python
import hashlib
import hmac
import base64
import time
import json
import requests

ACCESS_ID   = "your_access_id"
ACCESS_KEY  = "your_access_key"
ACCOUNT_NAME = "acme"

BASE_URL = f"https://{ACCOUNT_NAME}.logicmonitor.com/santaba/rest"


def lm_get(path):
    epoch = str(int(time.time() * 1000))
    request_vars = "GET" + epoch + path
    hmac1 = hmac.new(
        ACCESS_KEY.encode(),
        msg=request_vars.encode(),
        digestmod=hashlib.sha256,
    ).hexdigest()
    signature = base64.b64encode(hmac1.encode()).decode()
    auth = f"LMv1 {ACCESS_ID}:{signature}:{epoch}"
    headers = {"Content-Type": "application/json", "Authorization": auth, "X-Version": "3"}
    response = requests.get(BASE_URL + path, headers=headers)
    response.raise_for_status()
    return response.json()


# Step 1: get all collector groups, print numOfHosts for each
print("=== GET /setting/collector/groups (list) ===")
groups = lm_get("/setting/collector/groups")
for item in groups.get("items", []):
    print(f"  id={item['id']:4d}  name={item['name']!r:40s}  "
          f"numOfHosts={item['numOfHosts']}  numOfInstances={item['numOfInstances']}")

# Step 2: for each group, get the ById response and compare
print()
print("=== GET /setting/collector/groups/{id} (by id) ===")
for item in groups.get("items", []):
    gid = item["id"]
    detail = lm_get(f"/setting/collector/groups/{gid}")
    d = detail.get("data") or detail  # response shape varies
    # unwrap if needed
    if isinstance(d, dict) and "id" not in d:
        d = list(d.values())[0] if d else d
    print(f"  id={gid:4d}  name={item['name']!r:40s}  "
          f"numOfHosts={d.get('numOfHosts', '?')}  numOfInstances={d.get('numOfInstances', '?')}")
```

### Expected output

Every `numOfHosts` in the list response should match the `numOfHosts` in the ById
response for the same group. Instead, the list always shows `0`:

```
=== GET /setting/collector/groups (list) ===
  id=  64  name='z_david_marsh_collector_group'   numOfHosts=0  numOfInstances=0
  id=   1  name='@default'                        numOfHosts=0  numOfInstances=0
  ...

=== GET /setting/collector/groups/{id} (by id) ===
  id=  64  name='z_david_marsh_collector_group'   numOfHosts=6  numOfInstances=1225
  id=   1  name='@default'                        numOfHosts=6  numOfInstances=0
  ...
```
