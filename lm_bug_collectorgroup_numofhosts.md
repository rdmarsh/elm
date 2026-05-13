# Bug: `numOfHosts` always zero in GET /setting/collector/groups

`GET /setting/collector/groups` returns `numOfHosts: 0` for every group.
`GET /setting/collector/groups/{id}` returns the correct value for the same group.

## Actual vs expected

| Endpoint | `numOfHosts` |
|---|---|
| `GET /setting/collector/groups` | **0** (always) |
| `GET /setting/collector/groups/{id}` | **6** (correct) |

## Reproduction

```python
import hashlib, hmac, base64, time, requests

ACCESS_ID    = "your_access_id"
ACCESS_KEY   = "your_access_key"
ACCOUNT_NAME = "acme"

BASE_URL = f"https://{ACCOUNT_NAME}.logicmonitor.com/santaba/rest"

def lm_get(path):
    epoch = str(int(time.time() * 1000))
    h = hmac.new(ACCESS_KEY.encode(), ("GET" + epoch + path).encode(), hashlib.sha256)
    auth = f"LMv1 {ACCESS_ID}:{base64.b64encode(h.hexdigest().encode()).decode()}:{epoch}"
    r = requests.get(BASE_URL + path, headers={"Authorization": auth, "X-Version": "3"})
    r.raise_for_status()
    return r.json()

groups = lm_get("/setting/collector/groups")
for g in groups["items"]:
    detail = lm_get(f"/setting/collector/groups/{g['id']}")["data"]
    print(f"id={g['id']}  list.numOfHosts={g['numOfHosts']}  byid.numOfHosts={detail['numOfHosts']}")
```

### Output

```
id=64  list.numOfHosts=0  byid.numOfHosts=6
id=1   list.numOfHosts=0  byid.numOfHosts=4
...
```

## References

- [getCollectorGroupList](https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/#/Collector%20Groups/getCollectorGroupList)
- [getCollectorGroupById](https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/#/Collector%20Groups/getCollectorGroupById)
