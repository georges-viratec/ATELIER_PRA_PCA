import os
import sqlite3
from datetime import datetime
from flask import Flask, jsonify, request

DB_PATH = os.getenv("DB_PATH", "/data/app.db")

app = Flask(__name__)

# ---------- DB helpers ----------
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_conn()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            message TEXT NOT NULL
        )
    """)
    conn.commit()
    conn.close()

# ---------- Routes ----------

@app.get("/")
def hello():
    init_db()
    return jsonify(status="Bonjour tout le monde !")


@app.get("/health")
def health():
    init_db()
    return jsonify(status="ok")

@app.get("/add")
def add():
    init_db()

    msg = request.args.get("message", "hello")
    ts = datetime.utcnow().isoformat() + "Z"

    conn = get_conn()
    conn.execute(
        "INSERT INTO events (ts, message) VALUES (?, ?)",
        (ts, msg)
    )
    conn.commit()
    conn.close()

    return jsonify(
        status="added",
        timestamp=ts,
        message=msg
    )

@app.get("/consultation")
def consultation():
    init_db()

    conn = get_conn()
    cur = conn.execute(
        "SELECT id, ts, message FROM events ORDER BY id DESC LIMIT 50"
    )

    rows = [
        {"id": r[0], "timestamp": r[1], "message": r[2]}
        for r in cur.fetchall()
    ]

    conn.close()

    return jsonify(rows)

@app.get("/count")
def count():
    init_db()

    conn = get_conn()
    cur = conn.execute("SELECT COUNT(*) FROM events")
    n = cur.fetchone()[0]
    conn.close()

    return jsonify(count=n)


@app.get("/status")
def status():
    init_db()
    
    # Count des événements
    conn = get_conn()
    cur = conn.execute("SELECT COUNT(*) FROM events")
    event_count = cur.fetchone()[0]
    conn.close()
    
    # Dernier fichier de backup
    backup_dir = "/backup"
    last_backup_file = None
    backup_age_seconds = None
    
    try:
        if os.path.exists(backup_dir):
            # Liste tous les fichiers .db dans /backup
            backup_files = [
                f for f in os.listdir(backup_dir) 
                if f.endswith('.db')
            ]
            
            if backup_files:
                # Trie par date de modification 
                backup_files_with_time = [
                    (f, os.path.getmtime(os.path.join(backup_dir, f)))
                    for f in backup_files
                ]
                backup_files_with_time.sort(key=lambda x: x[1], reverse=True)
                
                # Le plus récent
                last_backup_file = backup_files_with_time[0][0]
                last_backup_mtime = backup_files_with_time[0][1]
                
                # Calcul de l'âge du backup
                current_time = datetime.now().timestamp()
                backup_age_seconds = int(current_time - last_backup_mtime)
    
    except Exception as e:
        pass
    
    return jsonify(
        count=event_count,
        last_backup_file=last_backup_file,
        backup_age_seconds=backup_age_seconds
    )


# ---------- Main ----------
if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=8080)
