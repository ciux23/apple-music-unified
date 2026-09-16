from flask import Flask, render_template, request, jsonify
import subprocess, threading, uuid, os, pty, select, re, json

app = Flask(__name__)
APMYX_BIN = "/app/apmyx"
CONFIG_PATH = "/app/apmyx-config.yaml"
jobs = {}

ANSI_RE = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
PROGRESS_RE = re.compile(r'AMDL_PROGRESS::(\{.*\})')

def strip_ansi(s):
    return ANSI_RE.sub('', s)

def update_quality(quality):
    mapping = {"aac": "AAC", "lossless": "ALAC", "hires": "ALAC", "atmos": "ATMOS"}
    value = mapping.get(quality, "ALAC")
    if not os.path.isfile(CONFIG_PATH):
        return
    with open(CONFIG_PATH, "r") as f:
        lines = f.readlines()
    found = False
    out = []
    for line in lines:
        if line.strip().startswith("preferred-quality:"):
            out.append(f'preferred-quality: {value}\n')
            found = True
        elif line.strip().startswith("alac-max:") and quality == "hires":
            out.append('alac-max: 192000\n')
        elif line.strip().startswith("alac-max:") and quality == "lossless":
            out.append('alac-max: 48000\n')
        else:
            out.append(line)
    if not found:
        out.append(f'preferred-quality: {value}\n')
    with open(CONFIG_PATH, "w") as f:
        f.writelines(out)

def parse_progress(line, job):
    m = PROGRESS_RE.search(line)
    if not m:
        return
    try:
        data = json.loads(m.group(1))
    except json.JSONDecodeError:
        return
    t = data.get("type", "")
    if t == "trackstream":
        job["current_track_name"] = data.get("name", "")
        job["total_tracks"] = data.get("totaltracks", 0)
    elif t == "track_start":
        job["track_num"] = data.get("track_num", 0)
        job["total_tracks"] = data.get("total_tracks", job.get("total_tracks", 0))
        job["total_bytes"] = data.get("total_bytes", 0)
        job["current_track_name"] = data.get("name", "")
    elif t == "track_complete":
        completed = data.get("track_num", 0)
        total = data.get("total_tracks", job.get("total_tracks", 1))
        job["track_num"] = completed
        if total:
            job["percent"] = int(100 * completed / total)

def reader(job_id, master_fd, proc):
    job = jobs[job_id]
    buf = ""
    try:
        while proc.poll() is None:
            r, _, _ = select.select([master_fd], [], [], 0.2)
            if master_fd in r:
                try:
                    data = os.read(master_fd, 4096)
                    if not data: break
                    text = strip_ansi(data.decode(errors="replace"))
                    job["log"] += text
                    buf += text
                    for ln in buf.split("\n")[:-1]:
                        parse_progress(ln, job)
                    buf = buf.split("\n")[-1]
                except OSError:
                    break
        while True:
            r, _, _ = select.select([master_fd], [], [], 0.2)
            if not r: break
            try:
                data = os.read(master_fd, 4096)
                if not data: break
                text = strip_ansi(data.decode(errors="replace"))
                job["log"] += text
            except OSError:
                break
    finally:
        job["status"] = "done"
        job["percent"] = 100

def run_apmyx(job_id, urls, quality):
    """urls è una lista di URL album/song da scaricare in sequenza."""
    jobs[job_id] = {
        "status": "running", "log": "", "master_fd": None, "proc": None,
        "percent": 0, "track_num": 0, "total_tracks": 0,
        "current_track_name": "", "total_bytes": 0,
        "current_index": 0, "total_urls": len(urls),
    }
    try:
        update_quality(quality)
        jobs[job_id]["log"] += f"[config] quality={quality}, {len(urls)} URL(s)\n\n"

        for i, url in enumerate(urls):
            jobs[job_id]["current_index"] = i + 1
            jobs[job_id]["log"] += f"\n=== [{i+1}/{len(urls)}] {url} ===\n"
            args = [APMYX_BIN]
            if "/song/" in url:
                args.append("-song")
            args.append(url)
            master_fd, slave_fd = pty.openpty()
            env = {**os.environ, "TERM": "dumb", "NO_COLOR": "1",
                   "COLUMNS": "160", "LINES": "60"}
            proc = subprocess.Popen(args, stdin=slave_fd, stdout=slave_fd,
                                    stderr=slave_fd, close_fds=True, env=env,
                                    cwd="/app")
            os.close(slave_fd)
            jobs[job_id]["master_fd"] = master_fd
            jobs[job_id]["proc"] = proc
            reader(job_id, master_fd, proc)
    except Exception as e:
        jobs[job_id]["log"] += f"\n[ERRORE] {e}"
        jobs[job_id]["status"] = "error"

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/resolve-artist", methods=["POST"])
def resolve_artist():
    """Risolve un URL artista nella lista album."""
    data = request.json
    url = data.get("url", "").strip()
    if not url:
        return jsonify({"error": "URL mancante"}), 400
    try:
        result = subprocess.run(
            [APMYX_BIN, "--resolve-artist", url, "--json-output"],
            capture_output=True, text=True, timeout=60, cwd="/app"
        )
        out = result.stdout
        start = out.find("AMDL_JSON_START")
        end = out.find("AMDL_JSON_END")
        if start == -1 or end == -1:
            return jsonify({"error": "Risposta non valida dal backend", "raw": out[:500]}), 500
        json_str = out[start + len("AMDL_JSON_START"):end].strip()
        albums_raw = json.loads(json_str)
        albums = []
        for a in albums_raw:
            attrs = a.get("attributes", {})
            albums.append({
                "id": a.get("id", ""),
                "name": attrs.get("name", ""),
                "url": attrs.get("url", ""),
                "release_date": attrs.get("releaseDate", ""),
                "track_count": attrs.get("trackCount", 0),
                "artwork": attrs.get("artwork", {}).get("url", "").replace("{w}x{h}", "300x300"),
            })
        return jsonify({"albums": albums})
    except subprocess.TimeoutExpired:
        return jsonify({"error": "Timeout nella risoluzione"}), 504
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/download", methods=["POST"])
def download():
    data = request.json
    urls = data.get("urls", [])
    if not urls:
        url = data.get("url", "").strip()
        if not url:
            return jsonify({"error": "URL mancante"}), 400
        urls = [url]
    quality = data.get("quality", "lossless")
    jid = str(uuid.uuid4())
    threading.Thread(target=run_apmyx, args=(jid, urls, quality), daemon=True).start()
    return jsonify({"job_id": jid})

@app.route("/send", methods=["POST"])
def send():
    data = request.json
    jid = data.get("job_id")
    text = data.get("text", "")
    j = jobs.get(jid)
    if not j or j.get("master_fd") is None:
        return jsonify({"error": "processo non attivo"}), 404
    try:
        os.write(j["master_fd"], (text + "\n").encode())
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": str(e)}), 500

@app.route("/log/<jid>")
def log(jid):
    j = jobs.get(jid)
    if not j:
        return jsonify({"error": "job non trovato"}), 404
    return jsonify({
        "status": j["status"],
        "log": j["log"],
        "percent": j.get("percent", 0),
        "track_num": j.get("track_num", 0),
        "total_tracks": j.get("total_tracks", 0),
        "current_track_name": j.get("current_track_name", ""),
        "current_index": j.get("current_index", 0),
        "total_urls": j.get("total_urls", 1),
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
