# core.py
import csv
import sqlite3
import os, datetime, re, binascii, hashlib, tempfile, threading, time, ipaddress
from itertools import chain
from urllib.parse import unquote
from flask import session, redirect, url_for, request, jsonify, abort, render_template_string
from werkzeug.security import generate_password_hash, check_password_hash
from functools import wraps
try:
    import duckdb
except Exception as exc:
    raise RuntimeError(
        "Le package 'duckdb' est requis pour la persistence CSV. Installe-le avec: pip install duckdb"
    ) from exc

# Shared <head> assets used by every inline template.
# Templates include the marker __HEAD_ASSETS__ inside their <head>;
# render_inline() substitutes it with this block before rendering.
COMMON_HEAD_ASSETS = (
    '  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">\n'
    '  <link href="{{ url_for(\'static\', filename=\'theme-pro.css\') }}" rel="stylesheet">\n'
    '  <script defer src="{{ url_for(\'static\', filename=\'app-shell.js\') }}" data-app-shell="1" data-username="{{ session.get(\'username\', \'\') }}" data-role="{{ \'admin\' if session.get(\'auth_ok\') else \'\' }}"></script>\n'
    '  <link rel="icon" type="image/svg+xml" href="{{ url_for(\'static\', filename=\'favicon.svg\') }}">\n'
    '  <link rel="alternate icon" type="image/png" sizes="32x32" href="{{ url_for(\'static\', filename=\'favicon.png\') }}">\n'
    '  <link rel="apple-touch-icon" sizes="180x180" href="{{ url_for(\'static\', filename=\'apple-touch-icon.png\') }}">'
)


def render_inline(tmpl: str, **context):
    """Render an inline template after substituting the __HEAD_ASSETS__ marker."""
    return render_template_string(tmpl.replace("__HEAD_ASSETS__", COMMON_HEAD_ASSETS), **context)


# -----------------------------
# Shared utilities
# -----------------------------
def as_reboot_flag(value) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return int(value) != 0
    txt = ("" if value is None else str(value)).strip().lower()
    return txt in {"1", "true", "yes", "on"}


def normalize_country_codes(raw: str) -> str:
    if not raw:
        return ""
    seen = set()
    out = []
    parts = re.split(r"[,\s;]+", raw)
    for p in parts:
        code = re.sub(r"[^A-Za-z0-9]", "", (p or "").strip()).upper()
        if not code or code in seen:
            continue
        seen.add(code)
        out.append(code)
    return ",".join(out)


def normalize_model_patterns(raw: str) -> str:
    if not raw:
        return ""
    parts = [p.strip() for p in re.split(r"[;\r\n]+", str(raw)) if p.strip()]
    return ";".join(parts)


def normalize_locale_tag(tag: str) -> str:
    if not tag:
        return ""
    s = tag.strip()
    if not s:
        return ""
    parts = s.split("-", 1)
    if len(parts) == 2:
        return parts[0].lower() + "-" + parts[1].upper()
    return s


def normalize_locale_list(raw: str) -> str:
    if not raw:
        return ""
    parts = []
    for p in raw.split("/"):
        p_norm = normalize_locale_tag(p)
        if p_norm:
            parts.append(p_norm)
    return " / ".join(parts)


def decode_display_text(value: str) -> str:
    txt = (value or "").strip()
    if not txt:
        return ""
    try:
        txt = unquote(txt)
    except Exception:
        pass
    return re.sub(r"\s+", " ", txt).strip()


def normalize_url(url_value: str) -> str:
    txt = (url_value or "").strip().strip('"').strip("'")
    if not txt:
        return ""
    return txt.replace(" ", "%20")


def file_label(url_value: str) -> str:
    clean_url = (url_value or "").split("?", 1)[0].strip()
    if not clean_url:
        return ""
    return decode_display_text(clean_url.rsplit("/", 1)[-1])


def safe_leaf_name(name: str) -> str:
    s = (name or "").strip()
    if not s or s in (".", ".."):
        return ""
    if "/" in s or "\\" in s or "\x00" in s:
        return ""
    return s


def safe_folder_name(name: str) -> str:
    s = (name or "").strip()
    if not s:
        return ""
    s = s.replace("/", "_").replace("\\", "_").replace(":", "_")
    s = "".join(ch for ch in s if ch.isalnum() or ch in ("-", "_", ".", " "))
    s = s.strip().strip(".")
    if not s or s in (".", ".."):
        return ""
    return s


# -----------------------------
# Config / DB
# -----------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_DIR  = os.path.join(BASE_DIR, "data_csv")
LOGS_DB_PATH = os.path.join(BASE_DIR, "logs", "logs.sqlite3")
LOGS_TABLE_NAME = "deployment_info"
TABLE_FILE_ALIASES = {
    "newcomputer": "computers",
    "postype_relations": "postype",
}
RETIRED_CSV_TABLES = {
    "configs",
    "drivers_unmapped",
    "log_check_report",
    "log_detect_report",
    "log_detect_report_clean",
}

_CSV_LOCK = threading.RLock()
_LOGS_LOCK = threading.RLock()

# Cross-process write lock for the CSV store. _CSV_LOCK serializes threads
# inside one process; this file lock serializes writers ACROSS processes, so a
# multi-worker deployment (gunicorn/uwsgi) cannot corrupt the CSV files — at
# worst writes serialize and slow down. Held only during a write transaction.
_CSV_FILE_LOCK_PATH = os.path.join(CSV_DIR, ".write.lock")
_csv_file_lock_state = threading.local()


def _acquire_csv_file_lock():
    os.makedirs(CSV_DIR, exist_ok=True)
    fh = open(_CSV_FILE_LOCK_PATH, "a+")
    try:
        try:
            import fcntl
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        except ImportError:
            import msvcrt
            fh.seek(0)
            while True:
                try:
                    msvcrt.locking(fh.fileno(), msvcrt.LK_LOCK, 1)
                    break
                except OSError:
                    time.sleep(0.1)
    except Exception:
        fh.close()
        raise
    _csv_file_lock_state.fh = fh


def _release_csv_file_lock():
    fh = getattr(_csv_file_lock_state, "fh", None)
    if fh is None:
        return
    try:
        try:
            import fcntl
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except ImportError:
            import msvcrt
            fh.seek(0)
            try:
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
            except OSError:
                pass
    finally:
        fh.close()
        _csv_file_lock_state.fh = None


def _configure_sqlite_for_logs(conn):
    try:
        conn.execute("PRAGMA journal_mode=WAL;")
    except sqlite3.OperationalError:
        pass
    try:
        conn.execute("PRAGMA synchronous=NORMAL;")
    except sqlite3.OperationalError:
        pass

# ---------- Auth model ----------
# This app is single-role by design: every authenticated account IS admin.
# There are no operator/viewer roles. require_roles(*roles) is kept because it
# decorates many GUI routes, but the role arguments are ignored on purpose:
# it only enforces that a valid (admin) session exists.
def _is_authenticated() -> bool:
    return session.get("auth_ok") is True or bool(session.get("uid"))

def current_role() -> str:
    return "admin" if _is_authenticated() else ""

def has_any_role(*roles) -> bool:
    return _is_authenticated()

def require_roles(*roles):
    def deco(f):
        @wraps(f)
        def _w(*a, **kw):
            if not _is_authenticated():
                return redirect(url_for("login", next=_build_next()))
            return f(*a, **kw)
        return _w
    return deco

# -----------------------------
# Public paths / prefixes
# -----------------------------
PUBLIC_GUI_PATHS = {
    "/login",
    "/logout",
    "/favicon.ico",
    "/healthz",
}

PUBLIC_API_PATHS = {
    "/message",       # POST { message }
    "/getcomputer",   # GET  ?serial=...
    "/setcomputer",   # POST { serial, computerName?, type?, ... }
    "/getapps",       # GET  ?type=...
    "/gettypes",      # GET  deployment type catalog
    "/getdrivers",    # GET  ?name=...&os=...
    "/list_used",     # GET  lists (types/keyboards)
    "/checkhardware", # GET  hardware compatibility before deployment
    "/tanium/global", # Tanium global webservice probe
    "/tanium/bundle", # Tanium bundle webservice probe
}

PUBLIC_API_PREFIXES = (
    "/file/",         # static files exposed by WS
)

STATIC_PREFIXES = (
    "/static/",
)

def _path_is_public(p: str) -> bool:
    """True if path is allowed without session/auth."""
    if not p:
        p = "/"
    p_noslash = p.rstrip("/") or "/"

    if p in PUBLIC_GUI_PATHS or p_noslash in PUBLIC_GUI_PATHS:
        return True
    if p in PUBLIC_API_PATHS or p_noslash in PUBLIC_API_PATHS:
        return True
    if any(p.startswith(pref) for pref in PUBLIC_API_PREFIXES):
        return True
    if any(p.startswith(pref) for pref in STATIC_PREFIXES):
        return True
    return False

def _build_next() -> str:
    """Build a redirect path that preserves the mount prefix (SCRIPT_NAME)."""
    base = request.script_root or ""
    if not base:
        fwd = request.headers.get("X-Forwarded-Prefix") or request.headers.get("X-Forwarded-Path")
        if fwd:
            base = fwd.rstrip("/")
    path = request.full_path or request.path or "/"
    if path.endswith("?"):
        path = path[:-1]
    if base and not path.startswith(base):
        return f"{base}{path}"
    return path

def guard():
    """Protect GUI; let public APIs/static through."""
    p = request.path or "/"

    # Public endpoints: no auth required
    if _path_is_public(p):
        return None

    # Authenticated session?
    if session.get("auth_ok") is True or session.get("uid"):
        return None

    # Non-public: redirect to login (GUI)
    return redirect(url_for("login", next=_build_next()))

# -----------------------------
# DB helpers
# -----------------------------
def _sql_ident(name: str) -> str:
    return '"' + (name or "").replace('"', '""') + '"'


def _table_to_csv_base(table_name: str) -> str:
    return TABLE_FILE_ALIASES.get(table_name, table_name)


def _csv_base_to_table(base_name: str) -> str:
    for table_name, csv_base in TABLE_FILE_ALIASES.items():
        if base_name == csv_base:
            return table_name
    return base_name


def _is_logs_table_name(table_name: str) -> bool:
    return (table_name or "").strip().lower() == LOGS_TABLE_NAME


def _migrate_csv_alias_files():
    def _csv_header(path: str):
        try:
            with open(path, "r", encoding="utf-8-sig", newline="") as f:
                reader = csv.reader(f)
                return next(reader, [])
        except Exception:
            return []

    def _ensure_csv_columns(path: str, expected_columns):
        if not os.path.exists(path):
            return

        with open(path, "r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            current_columns = list(reader.fieldnames or [])
            rows = list(reader)

        if not current_columns:
            return

        normalized = {c.strip().lower(): c for c in current_columns}
        missing = [c for c in expected_columns if c.strip().lower() not in normalized]
        if not missing:
            return

        final_columns = list(current_columns) + missing
        temp_path = None
        try:
            with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8", newline="", dir=CSV_DIR) as tf:
                temp_path = tf.name
                writer = csv.DictWriter(tf, fieldnames=final_columns, extrasaction="ignore")
                writer.writeheader()
                for row in rows:
                    for col in missing:
                        row[col] = ""
                    writer.writerow(row)
            os.replace(temp_path, path)
        finally:
            if temp_path and os.path.exists(temp_path):
                try:
                    os.remove(temp_path)
                except Exception:
                    pass

    for table_name, csv_base in TABLE_FILE_ALIASES.items():
        old_csv = os.path.join(CSV_DIR, f"{table_name}.csv")
        new_csv = os.path.join(CSV_DIR, f"{csv_base}.csv")
        if os.path.exists(old_csv) and not os.path.exists(new_csv):
            os.replace(old_csv, new_csv)
        elif os.path.exists(old_csv) and os.path.exists(new_csv):
            # If both exist, prefer the source file when target is legacy/incompatible.
            old_hdr = {h.strip().lower() for h in _csv_header(old_csv)}
            new_hdr = {h.strip().lower() for h in _csv_header(new_csv)}
            if table_name == "newcomputer":
                expected = {"macaddress", "computername", "postype", "setkeyboard"}
                old_hdr = {"macaddress" if h == "serial" else h for h in old_hdr}
                new_hdr = {"macaddress" if h == "serial" else h for h in new_hdr}
                old_ok = expected.issubset(old_hdr)
                new_ok = expected.issubset(new_hdr)
                if old_ok and not new_ok:
                    legacy_csv = os.path.join(CSV_DIR, f"{csv_base}_legacy.csv")
                    try:
                        os.replace(new_csv, legacy_csv)
                    except Exception:
                        pass
                    os.replace(old_csv, new_csv)

    _ensure_csv_columns(
        os.path.join(CSV_DIR, "drivers.csv"),
        ["model_regex", "os_regex", "url", "bundle_id", "min_ram_gb", "min_disk_gb", "min_cpu_count"],
    )

class Row:
    __slots__ = ("_cols", "_vals", "_idx")

    def __init__(self, columns, values):
        self._cols = list(columns or [])
        self._vals = tuple(values or ())
        self._idx = {c: i for i, c in enumerate(self._cols)}

    def __getitem__(self, key):
        if isinstance(key, int):
            return self._vals[key]
        if key in self._idx:
            return self._vals[self._idx[key]]
        low = str(key).lower()
        for c, i in self._idx.items():
            if str(c).lower() == low:
                return self._vals[i]
        raise KeyError(key)

    def __len__(self):
        return len(self._vals)

    def keys(self):
        return list(self._cols)

    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default


class CursorResult:
    def __init__(self, columns, rows):
        self._rows = [Row(columns, r) for r in (rows or [])]
        self._pos = 0

    @property
    def lastrowid(self):
        return None

    def fetchone(self):
        if self._pos >= len(self._rows):
            return None
        r = self._rows[self._pos]
        self._pos += 1
        return r

    def fetchall(self):
        if self._pos >= len(self._rows):
            return []
        out = self._rows[self._pos :]
        self._pos = len(self._rows)
        return out


def _adapt_sql(sql: str):
    q = (sql or "").strip()
    if not q:
        return "", (), []

    pre_sql = []
    if re.match(r"(?is)^\s*CREATE\s+TABLE\b", q):
        mt = re.match(r"(?is)^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([^\s(]+)", q)
        raw_table = mt.group(1) if mt else "t"
        table_base = raw_table.strip().strip('"').split(".")[-1].strip('"')

        def _mk_identity_sub(match):
            col = match.group(1)
            col_clean = col.strip().strip('"').replace(".", "_")
            seq_name = f"{table_base}_{col_clean}_seq".lower()
            pre_sql.append(f"CREATE SEQUENCE IF NOT EXISTS {_sql_ident(seq_name)} START 1;")
            return f"{col} BIGINT PRIMARY KEY DEFAULT nextval('{seq_name}')"

        q = re.sub(
            r'(?is)(["]?[a-zA-Z_][a-zA-Z0-9_]*["]?)\s+INTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT',
            _mk_identity_sub,
            q,
        )
        q = re.sub(
            r'(?is)(["]?[a-zA-Z_][a-zA-Z0-9_]*["]?)\s+(?:BIGINT|INTEGER)\s+PRIMARY\s+KEY\s+GENERATED\s+BY\s+DEFAULT\s+AS\s+IDENTITY',
            _mk_identity_sub,
            q,
        )
        # If schema already contains nextval('...'), ensure those sequences exist too.
        for seq_name in re.findall(r"(?is)nextval\(\s*'([^']+)'\s*\)", q):
            pre_sql.append(f"CREATE SEQUENCE IF NOT EXISTS {_sql_ident(seq_name)} START 1;")

    q = re.sub(r"(?is)datetime\(\s*'now'\s*\)", "CURRENT_TIMESTAMP", q)
    q = re.sub(r'(?is)datetime\(\s*"now"\s*\)', "CURRENT_TIMESTAMP", q)
    q = re.sub(r"(?is)\s+COLLATE\s+NOCASE", "", q)

    if re.match(r"(?is)^\s*INSERT\s+OR\s+IGNORE\s+INTO\s+", q):
        q = re.sub(r"(?is)^\s*INSERT\s+OR\s+IGNORE\s+INTO\s+", "INSERT INTO ", q)
        if "ON CONFLICT" not in q.upper():
            q = q.rstrip().rstrip(";") + " ON CONFLICT DO NOTHING;"
    return q, (), pre_sql


class CsvBackedConnection:
    def __init__(self):
        self._con = duckdb.connect(database=":memory:")
        self._closed = False
        self._csv_sync_enabled = True
        self._dirty = False
        self._holds_write_lock = False
        self._load_csv_to_conn()

    def _exec_raw(self, sql: str, params=()):
        if params is None:
            params = ()
        cur = self._con.execute(sql, params)
        cols = [d[0] for d in (cur.description or [])]
        rows = cur.fetchall() if cols else []
        return CursorResult(cols, rows)

    def execute(self, sql: str, params=()):
        if self._closed:
            raise RuntimeError("connection closed")
        adapted, forced_params, pre_sql = _adapt_sql(sql)
        if adapted == "":
            return CursorResult([], [])
        if self._is_mutating_sql(adapted):
            self._begin_write()
            self._dirty = True
        for pre in pre_sql:
            self._exec_raw(pre, ())
        use_params = forced_params if forced_params else (params or ())
        return self._exec_raw(adapted, use_params)

    def executescript(self, script: str):
        for chunk in (script or "").split(";"):
            stmt = chunk.strip()
            if stmt:
                self.execute(stmt + ";")
        return CursorResult([], [])

    def _begin_write(self):
        """Enter write mode: take the cross-thread + cross-process write lock
        and reload the latest committed CSV state, so concurrent writers can
        never overwrite each other (no lost update, no CSV corruption).

        The lock is held until commit()/close(). Read-only connections never
        call this and stay lock-free.
        """
        if self._holds_write_lock:
            return
        _CSV_LOCK.acquire()
        try:
            _acquire_csv_file_lock()
        except Exception:
            _CSV_LOCK.release()
            raise
        self._holds_write_lock = True
        # Drop the (possibly stale) read snapshot and reload fresh under lock.
        try:
            self._con.close()
        except Exception:
            pass
        self._con = duckdb.connect(database=":memory:")
        self._load_csv_to_conn()

    def _release_write_lock(self):
        if not self._holds_write_lock:
            return
        try:
            _release_csv_file_lock()
        finally:
            self._holds_write_lock = False
            _CSV_LOCK.release()

    def commit(self):
        if self._closed:
            return
        try:
            if self._csv_sync_enabled and self._dirty:
                self._export_conn_to_csv()
                self._dirty = False
        finally:
            self._release_write_lock()

    def close(self):
        if self._closed:
            return
        try:
            self.commit()
        except Exception:
            pass
        finally:
            self._release_write_lock()
            try:
                self._con.close()
            except Exception:
                pass
            self._closed = True

    def _is_mutating_sql(self, sql: str) -> bool:
        q = (sql or "").lstrip()
        if not q:
            return False
        m = re.match(r"(?is)^([a-z_]+)", q)
        if not m:
            return False
        op = m.group(1).lower()
        return op in {
            "insert", "update", "delete", "replace",
            "create", "alter", "drop", "truncate",
            "vacuum", "attach", "detach", "copy"
        }

    def _table_names(self):
        rows = self._exec_raw(
            "SELECT table_name FROM information_schema.tables WHERE table_schema='main' AND table_type='BASE TABLE' ORDER BY table_name;"
        ).fetchall()
        return [r["table_name"] for r in rows]

    def _export_conn_to_csv(self):
        os.makedirs(CSV_DIR, exist_ok=True)
        table_names = [
            t for t in self._table_names()
            if not _is_logs_table_name(t) and (t or "").strip().lower() not in RETIRED_CSV_TABLES
        ]
        for t in table_names:
            self._write_table_csv(t)

        keep = {f"{_table_to_csv_base(t)}.csv" for t in table_names}
        for name in os.listdir(CSV_DIR):
            if not name.endswith(".csv"):
                continue
            if name == f"{LOGS_TABLE_NAME}.csv":
                continue
            if name not in keep:
                try:
                    os.remove(os.path.join(CSV_DIR, name))
                except OSError:
                    pass

    def _write_table_csv(self, table_name: str):
        csv_base = _table_to_csv_base(table_name)
        col_meta = self.execute(f"PRAGMA table_info({_sql_ident(table_name)});").fetchall()
        cols = [r["name"] for r in col_meta]
        order_sql = " ORDER BY rowid" if table_name == "postype_relations" else ""
        rows = self._exec_raw(
            f"SELECT {', '.join(_sql_ident(c) for c in cols)} FROM {_sql_ident(table_name)}{order_sql};"
        ).fetchall() if cols else []

        csv_path = os.path.join(CSV_DIR, f"{csv_base}.csv")
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8", newline="", dir=CSV_DIR) as tf:
            writer = csv.writer(tf)
            header_cols = ["serial" if table_name == "newcomputer" and c == "macaddress" else c for c in cols]
            writer.writerow(header_cols)
            for row in rows:
                writer.writerow(["" if row[c] is None else str(row[c]) for c in cols])
            csv_tmp = tf.name
        os.replace(csv_tmp, csv_path)

    def _resync_identity_sequences(self, table_name: str):
        # When tables are reloaded from CSV into an in-memory DB, sequences restart.
        # Realign each nextval(...) sequence to MAX(column)+1 to keep IDs unique.
        table_ident = _sql_ident(table_name)
        col_meta = self.execute(f"PRAGMA table_info({table_ident});").fetchall()
        for col in col_meta:
            dflt = str(col.get("dflt_value") or "")
            m = re.search(r"(?is)nextval\s*\(\s*'([^']+)'\s*\)", dflt)
            if not m:
                continue
            seq_name = (m.group(1) or "").strip()
            if not seq_name:
                continue

            col_ident = _sql_ident(col["name"])
            seq_ident = _sql_ident(seq_name)
            row = self._exec_raw(
                f"SELECT COALESCE(MAX(TRY_CAST({col_ident} AS BIGINT)), 0) + 1 AS next_id FROM {table_ident};"
            ).fetchone()
            next_id = int((row["next_id"] if row and row["next_id"] is not None else 1))
            if next_id < 1:
                next_id = 1

            self._exec_raw(f"CREATE SEQUENCE IF NOT EXISTS {seq_ident} START 1;")
            # DuckDB syntax can vary by version; try common restart forms.
            restarted = False
            for stmt in (
                f"ALTER SEQUENCE {seq_ident} RESTART WITH {next_id};",
                f"ALTER SEQUENCE {seq_ident} RESTART {next_id};",
            ):
                try:
                    self._exec_raw(stmt)
                    restarted = True
                    break
                except Exception:
                    pass
            if not restarted:
                # Do not fail startup if sequence restart is unsupported.
                # The app can still run; sequence may be corrected on next writes.
                continue

    def _load_csv_table(self, table_name: str):
        csv_base = _table_to_csv_base(table_name)
        csv_path = os.path.join(CSV_DIR, f"{csv_base}.csv")

        if not os.path.exists(csv_path):
            return

        exists = self._exec_raw(
            "SELECT 1 FROM information_schema.tables WHERE table_schema='main' AND table_name=? LIMIT 1;",
            (table_name,),
        ).fetchone()

        with open(csv_path, "r", encoding="utf-8-sig", newline="") as f:
            reader = csv.reader(f)
            first_row = next(reader, None)
            if not first_row:
                return

            if not exists:
                # Legacy behavior: if there is no schema/table yet, first row is considered a header.
                columns = [str(c or "").strip() for c in first_row if str(c or "").strip()]
                if table_name == "newcomputer":
                    columns = ["macaddress" if str(c).strip().lower() == "serial" else c for c in columns]
                if not columns:
                    return
                col_defs = ", ".join(f"{_sql_ident(c)} TEXT" for c in columns)
                self._exec_raw(f"CREATE TABLE IF NOT EXISTS {_sql_ident(table_name)} ({col_defs});")
                data_rows = reader
            else:
                col_rows = self._exec_raw(f"PRAGMA table_info({_sql_ident(table_name)});").fetchall()
                table_cols = [r["name"] for r in col_rows if r and r["name"]]
                if not table_cols:
                    return

                table_cols_map = {str(c).strip().lower(): c for c in table_cols}
                if table_name == "newcomputer" and "macaddress" in table_cols_map:
                    table_cols_map["serial"] = table_cols_map["macaddress"]
                normalized_first = [str(c or "").strip().lower() for c in first_row]
                is_header = (
                    any(normalized_first)
                    and all(cell in table_cols_map for cell in normalized_first if cell)
                    and all(cell != "" for cell in normalized_first)
                )

                if is_header:
                    columns = [table_cols_map[cell] for cell in normalized_first]
                    data_rows = reader
                else:
                    columns = table_cols[: len(first_row)]
                    data_rows = chain([first_row], reader)

            placeholders = ", ".join("?" for _ in columns)
            col_sql = ", ".join(_sql_ident(c) for c in columns)
            ins_sql = f"INSERT INTO {_sql_ident(table_name)} ({col_sql}) VALUES ({placeholders});"
            for row in data_rows:
                if row is None:
                    continue
                values = [row[i] if i < len(row) else "" for i in range(len(columns))]
                self._exec_raw(ins_sql, values)

        self._resync_identity_sequences(table_name)

    def _load_csv_to_conn(self):
        with _CSV_LOCK:
            os.makedirs(CSV_DIR, exist_ok=True)
            _migrate_csv_alias_files()
            names = set()
            for name in os.listdir(CSV_DIR):
                if name.endswith(".csv"):
                    table_name = _csv_base_to_table(name[:-4])
                    if _is_logs_table_name(table_name) or table_name.lower() in RETIRED_CSV_TABLES:
                        continue
                    names.add(table_name)
            for table_name in sorted(names):
                self._load_csv_table(table_name)


def get_db():
    return CsvBackedConnection()


def ensure_logs_db():
    with _LOGS_LOCK:
        conn = sqlite3.connect(LOGS_DB_PATH)
        conn.row_factory = sqlite3.Row
        try:
            _configure_sqlite_for_logs(conn)
            conn.executescript(
                f"""
                CREATE TABLE IF NOT EXISTS {LOGS_TABLE_NAME}(
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  macaddress TEXT NOT NULL,
                  datetime   TEXT NOT NULL,
                  info       TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS ix_deploy_mac ON {LOGS_TABLE_NAME}(macaddress);
                CREATE INDEX IF NOT EXISTS ix_deploy_mac_id ON {LOGS_TABLE_NAME}(macaddress, id);
                CREATE INDEX IF NOT EXISTS ix_deploy_dt_id ON {LOGS_TABLE_NAME}(datetime DESC, id DESC);
                """
            )
            conn.commit()
        finally:
            conn.close()


def get_logs_db():
    ensure_logs_db()
    conn = sqlite3.connect(LOGS_DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

# ============================================================
# USERS — schema + helpers
# ============================================================
def ensure_users_schema():
    conn = get_db()
    try:
        # Users are keyed by username. Only two columns: username + password_hash.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users(
              username      TEXT PRIMARY KEY,
              password_hash TEXT
            );
        """)
        conn.commit()

        # Seed admin (no password) if empty
        c = conn.execute("SELECT COUNT(*) AS c FROM users;").fetchone()["c"]
        if c == 0:
            conn.execute(
                "INSERT INTO users (username, password_hash) VALUES ('admin','');"
            )
            conn.commit()
    finally:
        conn.close()

def get_user_by_username(username: str):
    if not username:
        return None
    conn = get_db()
    try:
        return conn.execute("SELECT * FROM users WHERE username = ? LIMIT 1;", (username.strip(),)).fetchone()
    finally:
        conn.close()

def _verify_password(stored_hash: str, provided: str) -> bool:
    stored = stored_hash or ""
    pwd    = provided or ""
    if stored == "":
        return pwd == ""
    if stored.startswith("sha256:"):
        try:
            alg_iters, salt_hex, digest_hex = stored.split("$", 2)
            iters = int(alg_iters.split(":", 1)[1])
            salt  = binascii.unhexlify(salt_hex.encode())
            dk    = hashlib.pbkdf2_hmac("sha256", pwd.encode("utf-8"), salt, iters)
            return binascii.hexlify(dk).decode() == digest_hex
        except Exception:
            return False
    try:
        return check_password_hash(stored, pwd)
    except Exception:
        return False

def authenticate(username: str, password: str):
    u = get_user_by_username(username)
    if not u:
        return None
    if not _verify_password(u["password_hash"], password):
        return None
    return u

def update_last_login(username: str):
    return None

def set_user_password(username: str, new_password: str):
    ph = "" if not new_password else generate_password_hash(new_password)
    conn = get_db()
    try:
        conn.execute(
            "UPDATE users SET password_hash=? WHERE username=?;",
            (ph, username)
        )
        conn.commit()
    finally:
        conn.close()

def create_user(username: str, password: str):
    ph   = "" if not password else generate_password_hash(password)
    conn = get_db()
    try:
        conn.execute(
            "INSERT INTO users (username, password_hash) VALUES (?, ?);",
            (username.strip(), ph)
        )
        conn.commit()
    finally:
        conn.close()

# ============================================================
# CONFIG — global key/value settings (config.csv -> table "config")
# ============================================================
CONFIG_DEFAULTS = {
    "default_bundle_id": "",
    "default_bundle_timeout": "120",
}

def ensure_config_schema():
    conn = get_db()
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS config(
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL DEFAULT ''
            );
        """)
        conn.commit()
        for key, default in CONFIG_DEFAULTS.items():
            exists = conn.execute("SELECT 1 FROM config WHERE key = ? LIMIT 1;", (key,)).fetchone()
            if not exists:
                conn.execute("INSERT INTO config (key, value) VALUES (?, ?);", (key, default))
        conn.commit()
    finally:
        conn.close()

def get_config(key: str, default: str = "") -> str:
    conn = get_db()
    try:
        row = conn.execute("SELECT value FROM config WHERE key = ? LIMIT 1;", (key,)).fetchone()
        if row is None:
            return default
        val = row["value"]
        return default if val is None else str(val)
    finally:
        conn.close()

def get_all_config() -> dict:
    conn = get_db()
    try:
        rows = conn.execute("SELECT key, value FROM config;").fetchall()
        return {str(r["key"]): ("" if r["value"] is None else str(r["value"])) for r in rows}
    finally:
        conn.close()

def set_config(key: str, value: str):
    conn = get_db()
    try:
        exists = conn.execute("SELECT 1 FROM config WHERE key = ? LIMIT 1;", (key,)).fetchone()
        if exists:
            conn.execute("UPDATE config SET value = ? WHERE key = ?;", (str(value), key))
        else:
            conn.execute("INSERT INTO config (key, value) VALUES (?, ?);", (key, str(value)))
        conn.commit()
    finally:
        conn.close()

# ============================================================
# APP DATA — autres tables
# ============================================================
def ensure_db():
    conn = get_db()
    try:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS newcomputer(
              macaddress   TEXT PRIMARY KEY,
              computername TEXT NOT NULL,
              postype      TEXT NOT NULL,
              country      TEXT NOT NULL DEFAULT '',
              language     TEXT NOT NULL DEFAULT '',
              timezone     TEXT NOT NULL DEFAULT '',
              setkeyboard  TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS drivers(
              model_regex TEXT NOT NULL,
              os_regex    TEXT NOT NULL,
              url         TEXT NOT NULL,
              bundle_id   TEXT NOT NULL DEFAULT '',
              min_ram_gb  TEXT NOT NULL DEFAULT '',
              min_disk_gb TEXT NOT NULL DEFAULT '',
              min_cpu_count TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS ix_drv_model_os ON drivers(model_regex, os_regex);
            
            CREATE TABLE IF NOT EXISTS apps(
              name        TEXT NOT NULL,
              url         TEXT NOT NULL,
              script      TEXT NOT NULL DEFAULT 'install.ps1',
              reboot      INTEGER NOT NULL DEFAULT 0,
              allowed_countries TEXT NOT NULL DEFAULT '',
              blocked_countries TEXT NOT NULL DEFAULT '',
              allowed_models TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS configs(
              id          INTEGER PRIMARY KEY AUTOINCREMENT,
              name        TEXT NOT NULL,
              url         TEXT NOT NULL,
              script      TEXT NOT NULL DEFAULT 'install.ps1',
              reboot      INTEGER NOT NULL DEFAULT 0,
              allowed_countries TEXT NOT NULL DEFAULT '',
              blocked_countries TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS postype_relations(
              postype     TEXT NOT NULL,
              application TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS ix_postype_rel_postype ON postype_relations(postype);
            """
        )
        conn.commit()

        try:
            conn.execute("SELECT country FROM newcomputer LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE newcomputer ADD COLUMN country TEXT;")
            conn.execute("UPDATE newcomputer SET country = '' WHERE country IS NULL;")

        try:
            conn.execute("SELECT language FROM newcomputer LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE newcomputer ADD COLUMN language TEXT;")
            conn.execute("UPDATE newcomputer SET language = '' WHERE language IS NULL;")

        try:
            conn.execute("SELECT timezone FROM newcomputer LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE newcomputer ADD COLUMN timezone TEXT;")
            conn.execute("UPDATE newcomputer SET timezone = '' WHERE timezone IS NULL;")

        try:
            conn.execute("SELECT min_ram_gb FROM drivers LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE drivers ADD COLUMN min_ram_gb TEXT;")
            conn.execute("UPDATE drivers SET min_ram_gb = '' WHERE min_ram_gb IS NULL;")

        try:
            conn.execute("SELECT min_disk_gb FROM drivers LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE drivers ADD COLUMN min_disk_gb TEXT;")
            conn.execute("UPDATE drivers SET min_disk_gb = '' WHERE min_disk_gb IS NULL;")

        try:
            conn.execute("SELECT min_cpu_count FROM drivers LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE drivers ADD COLUMN min_cpu_count TEXT;")
            conn.execute("UPDATE drivers SET min_cpu_count = '' WHERE min_cpu_count IS NULL;")

        try:
            conn.execute("SELECT reboot FROM apps LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE apps ADD COLUMN reboot INTEGER NOT NULL DEFAULT 0;")

        try:
            conn.execute("SELECT script FROM apps LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE apps ADD COLUMN script TEXT NOT NULL DEFAULT 'install.ps1';")

        try:
            conn.execute("SELECT allowed_countries FROM apps LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE apps ADD COLUMN allowed_countries TEXT;")
            conn.execute("UPDATE apps SET allowed_countries = '' WHERE allowed_countries IS NULL;")

        try:
            conn.execute("SELECT blocked_countries FROM apps LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE apps ADD COLUMN blocked_countries TEXT;")
            conn.execute("UPDATE apps SET blocked_countries = '' WHERE blocked_countries IS NULL;")

        try:
            conn.execute("SELECT allowed_models FROM apps LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE apps ADD COLUMN allowed_models TEXT;")
            conn.execute("UPDATE apps SET allowed_models = '' WHERE allowed_models IS NULL;")

        try:
            conn.execute("SELECT reboot FROM configs LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE configs ADD COLUMN reboot INTEGER NOT NULL DEFAULT 0;")

        try:
            conn.execute("SELECT script FROM configs LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE configs ADD COLUMN script TEXT NOT NULL DEFAULT 'install.ps1';")

        try:
            conn.execute("SELECT allowed_countries FROM configs LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE configs ADD COLUMN allowed_countries TEXT;")
            conn.execute("UPDATE configs SET allowed_countries = '' WHERE allowed_countries IS NULL;")

        try:
            conn.execute("SELECT blocked_countries FROM configs LIMIT 1;")
        except Exception:
            conn.execute("ALTER TABLE configs ADD COLUMN blocked_countries TEXT;")
            conn.execute("UPDATE configs SET blocked_countries = '' WHERE blocked_countries IS NULL;")

        conn.commit()
    finally:
        conn.close()

# ============================================================
# Utils (déploiement)
# ============================================================
def normalize_id(raw_id: str) -> str:
    if raw_id is None:
        return ""
    return (
        raw_id.replace(":", "")
              .replace("-", "")
              .replace(" ", "")
              .upper()
              .strip()
    )

def ensure_computer_placeholder(conn, raw_id: str):
    norm = normalize_id(raw_id)
    if not norm:
        return
    row = conn.execute(
        """
        SELECT macaddress
        FROM newcomputer
        WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?
        LIMIT 1;
        """,
        (norm,),
    ).fetchone()
    if row is None:
        conn.execute(
            """
            INSERT INTO newcomputer (macaddress, computername, postype, setkeyboard)
            VALUES (?, '', '', '');
            """,
            (norm,),
        )
        conn.commit()

def insert_deploy_log(conn, serial: str, info_text: str):
    norm = normalize_id(serial)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    is_start = "START PROVISION" in (info_text or "").upper()

    if is_start:
        conn.execute(
            "DELETE FROM deployment_info WHERE macaddress = ?;",
            (norm,),
        )

    conn.execute(
        "INSERT INTO deployment_info (macaddress, datetime, info) VALUES (?, ?, ?);",
        (norm, ts, info_text),
    )
    conn.commit()
    return ts

def parse_serial_and_message(full_msg: str):
    serial = "UNKNOWN"
    text = full_msg
    if full_msg.startswith("[") and "]" in full_msg:
        bracket_end = full_msg.find("]")
        maybe_serial = full_msg[1:bracket_end].strip()
        rest = full_msg[bracket_end + 1:].lstrip()
        if maybe_serial:
            serial = maybe_serial.upper().replace(" ", "")
            text = rest
    return (serial, text)

def collect_types(conn, exclude_common=True):
    types_set = set()
    for r in conn.execute(
        "SELECT DISTINCT postype FROM postype_relations WHERE postype IS NOT NULL AND postype <> '';"
    ).fetchall():
        types_set.add(str(r["postype"]).strip().upper())
    for r in conn.execute(
        "SELECT DISTINCT postype FROM newcomputer WHERE postype IS NOT NULL AND postype <> '';"
    ).fetchall():
        types_set.add(str(r["postype"]).strip().upper())
    if exclude_common:
        types_set = {t for t in types_set if t.upper() != "COMMON"}
    return sorted(types_set, key=lambda x: x.lower())

# ============================================================
# NETWORK ACCESS CONTROL (Option A — network restriction)
# ============================================================
# Each source network that hits the machine-facing surface is inventoried in
# data_csv/networks.csv. Everything is "Blocked" by default; an admin flips an
# entry to "Allow" (or adds an arbitrary CIDR manually) via the Network menu.
#
# Classification rule:
#   - Private RFC1918 address  -> the whole private block is the key:
#       10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
#   - Any other (public) address -> behind NAT -> only that single IP (/32),
#     or /128 for IPv6.
NETWORKS_TABLE = "networks"
_PRIVATE_BLOCKS = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
_PRIVATE_NETWORKS = tuple(ipaddress.ip_network(b) for b in _PRIVATE_BLOCKS)

_networks_cache_lock = threading.RLock()
_networks_cache = {"mtime": None, "allow": [], "known": set(), "all_nets": []}


def _networks_csv_path() -> str:
    return os.path.join(CSV_DIR, "networks.csv")


def _clean_source_ip(raw: str) -> str:
    """Strip an optional ':port' (and IPv6 brackets) from a source address.

    Some proxies put 'ip:port' into X-Forwarded-For, so request.remote_addr can
    arrive as '10.42.126.7:48438'. ipaddress can't parse that, which would make
    every such client look blocked. Reduce it to the bare IP here.
    """
    s = (raw or "").strip()
    if not s:
        return ""
    if s.startswith("["):              # [IPv6]:port
        return s[1:].split("]", 1)[0]
    if s.count(":") == 1:              # IPv4:port
        return s.split(":", 1)[0]
    return s                           # bare IPv4 or bare IPv6


def classify_network(ip_str: str):
    """Map a client IP to its network key. Returns {'network','kind'} or None."""
    s = _clean_source_ip(ip_str)
    if not s:
        return None
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return None
    if ip.version == 4:
        for block in _PRIVATE_NETWORKS:
            if ip in block:
                return {"network": str(block), "kind": "subnet"}
        return {"network": f"{ip}/32", "kind": "host"}
    return {"network": f"{ip}/128", "kind": "host"}


def is_network_gated_path(p: str) -> bool:
    """Machine-facing surface protected by the network filter: device/Tanium
    APIs and the file repository. The admin GUI, login and static assets are
    NEVER gated, so an admin can always connect and unblock a network."""
    if not p:
        return False
    p_noslash = p.rstrip("/") or "/"
    if p in PUBLIC_API_PATHS or p_noslash in PUBLIC_API_PATHS:
        return True
    if any(p.startswith(pref) for pref in PUBLIC_API_PREFIXES):
        return True
    return False


def ensure_networks_schema():
    """Create the networks table and seed the private blocks as Blocked."""
    conn = get_db()
    try:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS networks(
              network    TEXT PRIMARY KEY,
              kind       TEXT NOT NULL DEFAULT 'subnet',
              status     TEXT NOT NULL DEFAULT 'Blocked',
              first_seen TEXT NOT NULL DEFAULT '',
              last_seen  TEXT NOT NULL DEFAULT '',
              hits       INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        conn.commit()

        c = conn.execute("SELECT COUNT(*) AS c FROM networks;").fetchone()["c"]
        if int(c or 0) == 0:
            now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            for block in _PRIVATE_BLOCKS:
                conn.execute(
                    "INSERT INTO networks (network, kind, status, first_seen, last_seen, hits) "
                    "VALUES (?, 'subnet', 'Blocked', ?, ?, 0);",
                    (block, now, now),
                )
            conn.commit()
    finally:
        conn.close()
    _invalidate_networks_cache()


def _invalidate_networks_cache():
    with _networks_cache_lock:
        _networks_cache["mtime"] = None


def _refresh_networks_cache():
    path = _networks_csv_path()
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = None
    with _networks_cache_lock:
        if _networks_cache["mtime"] == mtime:
            return
        allow = []
        known = set()
        all_nets = []
        if mtime is not None:
            try:
                with open(path, "r", encoding="utf-8-sig", newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        net = (row.get("network") or "").strip()
                        status = (row.get("status") or "").strip().lower()
                        if not net:
                            continue
                        known.add(net)
                        try:
                            parsed = ipaddress.ip_network(net, strict=False)
                        except ValueError:
                            parsed = None
                        if parsed is not None:
                            all_nets.append(parsed)
                            if status == "allow":
                                allow.append(parsed)
            except OSError:
                pass
        _networks_cache["mtime"] = mtime
        _networks_cache["allow"] = allow
        _networks_cache["known"] = known
        _networks_cache["all_nets"] = all_nets


def is_ip_allowed(ip_str: str) -> bool:
    """True if the IP falls inside at least one Allowed network/range."""
    _refresh_networks_cache()
    s = _clean_source_ip(ip_str)
    if not s:
        return False
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return False
    with _networks_cache_lock:
        allow = list(_networks_cache["allow"])
    for net in allow:
        try:
            if ip in net:
                return True
        except TypeError:
            # IPv4 address vs IPv6 network (or vice versa): not a match.
            continue
    return False


def record_network_seen(ip_str: str):
    """Record a newly seen network as Blocked, but only if the source IP is not
    already covered by an existing entry (Allow or Blocked).

    This bounds growth: add one broad Blocked range (e.g. 0.0.0.0/0, or your
    public supernets) and individual public IPs falling inside it will no longer
    create per-IP /32 rows.
    """
    s = _clean_source_ip(ip_str)
    if not s:
        return
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return
    info = classify_network(s)
    if not info:
        return
    _refresh_networks_cache()
    with _networks_cache_lock:
        all_nets = list(_networks_cache["all_nets"])
    for existing in all_nets:
        try:
            if ip in existing:
                return  # already covered by an existing range/entry
        except TypeError:
            continue
    net = info["network"]
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = get_db()
    try:
        exists = conn.execute(
            "SELECT 1 FROM networks WHERE network = ? LIMIT 1;", (net,)
        ).fetchone()
        if not exists:
            conn.execute(
                "INSERT INTO networks (network, kind, status, first_seen, last_seen, hits) "
                "VALUES (?, ?, 'Blocked', ?, ?, 1);",
                (net, info["kind"], now, now),
            )
            conn.commit()
    finally:
        conn.close()
    _invalidate_networks_cache()
