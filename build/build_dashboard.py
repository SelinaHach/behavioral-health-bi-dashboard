import pathlib
R = pathlib.Path(__file__).resolve().parents[1]
t = (R/"build"/"dashboard_template.html").read_text()
d = (R/"results"/"dashboard_data.json").read_text()
(R/"dashboard"/"index.html").parent.mkdir(exist_ok=True)
(R/"dashboard"/"index.html").write_text(t.replace("__DATA__", d))
# standalone version with a document skeleton for local viewing / GitHub Pages
(R/"dashboard"/"behavioral_health_dashboard_standalone.html").write_text(
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">' +
    t.replace("__DATA__", d).replace("<style>", "<style>body{margin:0}", 1) + "</html>")
print("ok")
