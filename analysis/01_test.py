

print("Hello, World!")
# Shift + Enter to step trough

import requests, pandas as pd, time

BASE = "https://fantasy.premierleague.com/api"
boot = requests.get(f"{BASE}/bootstrap-static/").json()
names = {p["id"]: p["web_name"] for p in boot["elements"]}
done = [e["id"] for e in boot["events"] if e["finished"]]

rows = []
for gw in done:
    for e in requests.get(f"{BASE}/event/{gw}/live/").json()["elements"]:
        rows.append({"gw": gw, "player": names[e["id"]], **e["stats"]})
    time.sleep(1)

pd.DataFrame(rows).to_csv("fpl_gw_stats.csv", index=False)

