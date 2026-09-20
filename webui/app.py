from flask import Flask, render_template, request, jsonify
import subprocess, threading, uuid, os, pty, select, re, json, time, glob, shutil

app = Flask(__name__)
APMYX_BIN = "/app/apmyx"
CONFIG_PATH = "/app/apmyx-config.yaml"
LOGIN_REQ = "/app/.login-request"
LOGIN_STATUS = "/app/.login-status"
TWO_FA_FILE = "/app/rootfs/data/2fa.txt"
TOKEN_REQ = "/app/.token-input"
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
    finally:
        job["status"] = "done"
        job["percent"] = 100


def convert_to_flac(job_id, files, keep_alac=False):
    """Converte i file .m4a passati in FLAC dentro /downloads/FLAC/.
    Preserva struttura, tag e copertina (ridimensionata per il limite FLAC di 16 MB)."""
    jobs[job_id]["log"] += "\n[FLAC] Conversione in corso...\n"
    src_root = "/downloads/ALAC"
    dst_root = "/downloads/FLAC"
    if not files:
        jobs[job_id]["log"] += "[FLAC] Nessun file nuovo da convertire.\n"
        return
    total = len(files)
    jobs[job_id]["log"] += f"[FLAC] {total} file da convertire.\n"
    for idx, src in enumerate(files, 1):
        rel = os.path.relpath(src, src_root)
        dst = os.path.join(dst_root, os.path.splitext(rel)[0] + ".flac")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        # ffmpeg: audio in flac, copertina ridimensionata a 1400x1400 mjpeg per stare sotto il limite 16 MB
        cmd = [
            "ffmpeg", "-y", "-i", src,
            "-map", "0:a", "-map", "0:v?",
            "-c:a", "flac", "-compression_level", "8",
            "-c:v", "mjpeg", "-q:v", "3", "-vf", "scale=1400:1400:force_original_aspect_ratio=decrease",
            "-disposition:v", "attached_pic",
            "-map_metadata", "0",
            dst
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            if result.returncode != 0:
                jobs[job_id]["log"] += f"[FLAC] [{idx}/{total}] errore su {rel}: {result.stderr[-200:]}\n"
                continue
            jobs[job_id]["log"] += f"[FLAC] [{idx}/{total}] {rel} -> FLAC\n"
            if not keep_alac:
                os.remove(src)
        except Exception as e:
            jobs[job_id]["log"] += f"[FLAC] [{idx}/{total}] eccezione su {rel}: {e}\n"
    # Rimuovi cartelle ALAC vuote
    for root, dirs, files_ in os.walk(src_root, topdown=False):
        if root == src_root:
            continue
        try:
            if not os.listdir(root):
                os.rmdir(root)
        except OSError:
            pass
    if not keep_alac:
        # Cancella completamente la cartella ALAC: è solo un volano per la conversione
        try:
            if os.path.isdir(src_root):
                shutil.rmtree(src_root)
                jobs[job_id]["log"] += "[FLAC] Cartella ALAC rimossa (volano non più necessario).\n"
        except OSError as e:
            jobs[job_id]["log"] += f"[FLAC] Impossibile rimuovere ALAC: {e}\n"
    jobs[job_id]["log"] += "[FLAC] Conversione completata.\n"

def run_apmyx(job_id, urls, quality, output_format='alac'):
    jobs[job_id] = {
        "status": "running", "log": "", "master_fd": None, "proc": None,
        "percent": 0, "track_num": 0, "total_tracks": 0,
        "current_track_name": "", "current_index": 0, "total_urls": len(urls),
    }
    try:
        update_quality(quality)
        jobs[job_id]["log"] += f"[config] quality={quality}, format={output_format}, {len(urls)} URL(s)\n\n"
        # Snapshot dei file .m4a esistenti prima del download
        existing = set(glob.glob(os.path.join("/downloads/ALAC", "**", "*.m4a"), recursive=True))
        jobs[job_id]["log"] += f"[config] file esistenti in ALAC: {len(existing)}\n\n"
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
                                    stderr=slave_fd, close_fds=True, env=env, cwd="/app")
            os.close(slave_fd)
            jobs[job_id]["master_fd"] = master_fd
            jobs[job_id]["proc"] = proc
            reader(job_id, master_fd, proc)
        # Conversione FLAC se richiesta - solo file nuovi
        if output_format in ("flac", "alac+flac"):
            keep = (output_format == "alac+flac")
            current = set(glob.glob(os.path.join("/downloads/ALAC", "**", "*.m4a"), recursive=True))
            new_files = sorted(current - existing)
            jobs[job_id]["log"] += f"\n[FLAC] {len(new_files)} file nuovi da convertire.\n"
            convert_to_flac(job_id, new_files, keep_alac=keep)
    except Exception as e:
        jobs[job_id]["log"] += f"\n[ERRORE] {e}"
        jobs[job_id]["status"] = "error"

# ---------------------------------------------------------------------------
# Setup wizard endpoints
# ---------------------------------------------------------------------------
@app.route("/setup/status")
def setup_status():
    """Ritorna lo stato del wizard: waiting, 2fa, ok, error."""
    status = "waiting"
    if os.path.isfile(LOGIN_STATUS):
        with open(LOGIN_STATUS) as f:
            status = f.read().strip()
    return jsonify({"status": status})

@app.route("/setup/login", methods=["POST"])
def setup_login():
    data = request.json
    email = data.get("email", "").strip()
    password = data.get("password", "")
    if not email or not password:
        return jsonify({"error": "Email e password obbligatorie"}), 400
    # Sostituiamo eventuali ":" nella password (il formato interno è email:password)
    # Usiamo il primo ":" come separatore: email non contiene ":"
    with open(LOGIN_REQ, "w") as f:
        f.write(f"{email}:{password}")
    os.chmod(LOGIN_REQ, 0o600)
    return jsonify({"ok": True})

@app.route("/setup/2fa", methods=["POST"])
def setup_2fa():
    data = request.json
    code = data.get("code", "").strip()
    if not code or not code.isdigit():
        return jsonify({"error": "Codice 2FA non valido"}), 400
    with open(TWO_FA_FILE, "w") as f:
        f.write(code)
    return jsonify({"ok": True})

@app.route("/setup/token", methods=["POST"])
def setup_token():
    data = request.json
    token = data.get("token", "").strip()
    if not token:
        return jsonify({"error": "Token obbligatorio"}), 400
    with open(TOKEN_REQ, "w") as f:
        f.write(token)
    os.chmod(TOKEN_REQ, 0o600)
    return jsonify({"ok": True})

# ---------------------------------------------------------------------------
# Application endpoints
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html")

@app.route("/resolve-artist", methods=["POST"])
def resolve_artist():
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
            return jsonify({"error": "Risposta non valida dal backend"}), 500
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
    output_format = data.get("output_format", "alac")
    jid = str(uuid.uuid4())
    threading.Thread(target=run_apmyx, args=(jid, urls, quality, output_format), daemon=True).start()
    return jsonify({"job_id": jid})

@app.route("/log/<jid>")
def log(jid):
    j = jobs.get(jid)
    if not j:
        return jsonify({"error": "job non trovato"}), 404
    return jsonify({
        "status": j["status"], "log": j["log"],
        "percent": j.get("percent", 0),
        "track_num": j.get("track_num", 0),
        "total_tracks": j.get("total_tracks", 0),
        "current_track_name": j.get("current_track_name", ""),
        "current_index": j.get("current_index", 0),
        "total_urls": j.get("total_urls", 1),
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, threaded=True)
