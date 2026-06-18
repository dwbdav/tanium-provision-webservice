"""
=============================================================================
bp_api_php.py - PHP API Integration Blueprint
=============================================================================

Handles API endpoints for external PHP-based deployments and device provisioning.

Features:
  - Computer registration and status tracking
  - Driver mapping and resolution
  - Deployment log recording
  - Multi-OS support (Windows, etc)
"""

from flask import Blueprint, request, jsonify
import datetime
import json
import os
import re
from core import (
    get_db,
    get_logs_db,
    ensure_computer_placeholder,
    normalize_id,
    normalize_locale_list,
    normalize_locale_tag,
    collect_types,
    insert_deploy_log,
    parse_serial_and_message,
    get_config,
)
from core import as_reboot_flag, normalize_url

bp = Blueprint("api_php", __name__)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TANIUM_GLOBAL_LOG = os.path.join(BASE_DIR, "logs", "tanium-global.log")
TANIUM_BUNDLE_LOG = os.path.join(BASE_DIR, "logs", "tanium-bundle.log")


def _norm_serial(s: str) -> str:
    """Normalize computer serial: uppercase + remove spaces, colons, dashes."""
    return (s or "").strip().upper().replace(" ", "").replace(":", "").replace("-", "")


def _norm_text(s: str, maxlen: int = 64) -> str:
    """Normalize text: strip whitespace and limit length."""
    return ((s or "").strip())[:maxlen]


def _ensure_app_config_columns(conn) -> None:
    for column, ddl in (
        ("script", "ALTER TABLE apps ADD COLUMN script TEXT NOT NULL DEFAULT 'install.ps1';"),
        ("allowed_models", "ALTER TABLE apps ADD COLUMN allowed_models TEXT NOT NULL DEFAULT '';"),
    ):
        try:
            conn.execute(f"SELECT {column} FROM apps LIMIT 1;")
        except Exception:
            conn.execute(ddl)
            conn.commit()


def _canonical_type(postype: str) -> str:
    if not postype:
        return ""
    wanted = postype.strip().upper()
    if not wanted:
        return ""
    conn = get_db()
    try:
        # If no reference type exists yet, accept incoming types (bootstrap mode).
        ref_count_row = conn.execute(
            """
            SELECT COUNT(*) AS c
            FROM (
              SELECT TRIM(IFNULL(postype,'')) AS postype FROM postype_relations
              UNION
              SELECT TRIM(IFNULL(postype,'')) AS postype FROM newcomputer
            )
            WHERE postype <> '';
            """
        ).fetchone()
        if (ref_count_row["c"] or 0) == 0:
            return wanted

        row = conn.execute(
            """
            SELECT TRIM(postype) AS postype
            FROM (
              SELECT postype FROM postype_relations
              UNION
              SELECT postype FROM newcomputer
            )
            WHERE UPPER(TRIM(IFNULL(postype,''))) = UPPER(?)
              AND TRIM(IFNULL(postype,'')) <> ''
            LIMIT 1;
            """,
            (wanted,),
        ).fetchone()
        return wanted if row else ""
    finally:
        conn.close()


def _type_exists(postype: str) -> bool:
    return bool(_canonical_type(postype))


# -------------------------------
# API: liste des valeurs disponibles
# -------------------------------
@bp.route("/list_used", methods=["GET"])
def api_list_used():
    """
    Retourne les valeurs disponibles:
      - postype: catalogue postype_relations + valeurs déjà utilisées dans newcomputer
      - setkeyboard, country, language, timezone: valeurs déjà utilisées dans newcomputer
    Params:
      - counts=1  -> inclut le nombre d'occurrences par valeur
      - lower=0   -> ne pas forcer en minuscules (par défaut lower=1)
    """
    include_counts = str(request.args.get("counts", "0")).lower() in ("1", "true", "yes", "on")
    use_lower      = str(request.args.get("lower",  "1")).lower() in ("1", "true", "yes", "on")

    def col_expr(col: str) -> str:
        base = f"TRIM(IFNULL({col}, ''))"
        return f"LOWER({base})" if use_lower else base

    conn = get_db()
    try:
        type_selects    = []
        kbd_selects     = []
        country_selects = []
        lang_selects    = []
        timezone_selects = []

        type_selects.append(
            "SELECT UPPER(TRIM(IFNULL(postype, ''))) AS v FROM newcomputer WHERE TRIM(IFNULL(postype,'')) <> ''"
        )
        type_selects.append(
            "SELECT UPPER(TRIM(IFNULL(postype, ''))) AS v FROM postype_relations WHERE TRIM(IFNULL(postype,'')) <> ''"
        )
        kbd_selects.append(
            f"SELECT {col_expr('setkeyboard')} AS v FROM newcomputer WHERE TRIM(IFNULL(setkeyboard,'')) <> ''"
        )
        country_selects.append(
            f"SELECT {col_expr('country')} AS v FROM newcomputer WHERE TRIM(IFNULL(country,'')) <> ''"
        )
        lang_selects.append(
            f"SELECT {col_expr('language')} AS v FROM newcomputer WHERE TRIM(IFNULL(language,'')) <> ''"
        )
        timezone_selects.append(
            f"SELECT {col_expr('timezone')} AS v FROM newcomputer WHERE TRIM(IFNULL(timezone,'')) <> ''"
        )

        types     = []
        keyboards = []
        countries = []
        languages = []
        timezones = []

        if type_selects:
            if include_counts:
                t_query = f"""
                    SELECT v, SUM(n) AS n
                    FROM (
                      SELECT UPPER(TRIM(IFNULL(postype, ''))) AS v, COUNT(*) AS n
                      FROM newcomputer
                      WHERE TRIM(IFNULL(postype,'')) <> ''
                      GROUP BY v
                      UNION ALL
                      SELECT UPPER(TRIM(IFNULL(postype, ''))) AS v, 0 AS n
                      FROM postype_relations
                      WHERE TRIM(IFNULL(postype,'')) <> ''
                      GROUP BY v
                    ) t
                    GROUP BY v
                    ORDER BY v ASC;
                """
            else:
                t_query = "SELECT v, COUNT(*) AS n FROM (" + " UNION ALL ".join(type_selects) + ") t GROUP BY v ORDER BY v ASC;"
            k_query = "SELECT v, COUNT(*) AS n FROM (" + " UNION ALL ".join(kbd_selects)  + ") k GROUP BY v ORDER BY v ASC;"

            t_rows = conn.execute(t_query).fetchall()
            k_rows = conn.execute(k_query).fetchall()

            if include_counts:
                types     = [{"value": r["v"], "count": r["n"]} for r in t_rows]
                keyboards = [{"value": r["v"], "count": r["n"]} for r in k_rows]
            else:
                types     = [r["v"] for r in t_rows]
                keyboards = [r["v"] for r in k_rows]

        if country_selects:
            c_query = "SELECT v, COUNT(*) AS n FROM (" + " UNION ALL ".join(country_selects) + ") c GROUP BY v ORDER BY v ASC;"
            c_rows  = conn.execute(c_query).fetchall()
            if include_counts:
                countries = [{"value": r["v"], "count": r["n"]} for r in c_rows]
            else:
                countries = [r["v"] for r in c_rows]

        if lang_selects:
            l_query = "SELECT v, COUNT(*) AS n FROM (" + " UNION ALL ".join(lang_selects) + ") l GROUP BY v ORDER BY v ASC;"
            l_rows  = conn.execute(l_query).fetchall()
            if include_counts:
                languages = [{"value": r["v"], "count": r["n"]} for r in l_rows]
            else:
                languages = [r["v"] for r in l_rows]

        if timezone_selects:
            tz_query = "SELECT v, COUNT(*) AS n FROM (" + " UNION ALL ".join(timezone_selects) + ") tz GROUP BY v ORDER BY v ASC;"
            tz_rows  = conn.execute(tz_query).fetchall()
            if include_counts:
                timezones = [{"value": r["v"], "count": r["n"]} for r in tz_rows]
            else:
                timezones = [r["v"] for r in tz_rows]

        return jsonify({
            "types":     types,
            "keyboards": keyboards,
            "countries": countries,
            "languages": languages,
            "timezones": timezones,
        }), 200
    finally:
        conn.close()


@bp.route("/gettypes", methods=["GET"])
def api_gettypes():
    """
    Retourne les types connus depuis postype.csv et les postes affectés.
    """
    include_counts = str(request.args.get("counts", "0")).lower() in ("1", "true", "yes", "on")
    conn = get_db()
    try:
        types = collect_types(conn)
        if include_counts:
            rows = conn.execute(
                """
                SELECT UPPER(TRIM(IFNULL(postype, ''))) AS postype, COUNT(*) AS n
                FROM newcomputer
                WHERE TRIM(IFNULL(postype,'')) <> ''
                GROUP BY UPPER(TRIM(IFNULL(postype, '')));
                """
            ).fetchall()
            counts = {r["postype"]: r["n"] for r in rows}
            payload = [{"value": t, "count": counts.get(t, 0)} for t in types]
        else:
            payload = types
        return jsonify({"types": payload}), 200
    finally:
        conn.close()



# -------------------------------
# API: getcomputer
# -------------------------------
@bp.route("/getcomputer", methods=["GET"])
def api_getcomputer():
    serial = request.args.get("serial", default="", type=str)

    conn = get_db()
    ensure_computer_placeholder(conn, serial)
    norm = normalize_id(serial)

    row = conn.execute(
        """
        SELECT computername, postype, country, language, timezone, setkeyboard
        FROM newcomputer
        WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?
        LIMIT 1;
        """,
        (norm,),
    ).fetchone()

    if row is None:
        resp = {
            "computerName": None,
            "type":         None,
            "country":      None,
            "language":     None,
            "timezone":     None,
            "keyboard":     None,
        }
    else:
        compname = row["computername"]
        t        = (row["postype"] or "").strip().upper()
        c        = row["country"]
        lang     = row["language"]
        tz       = row["timezone"]
        kb       = row["setkeyboard"]
        resp = {
            "computerName": compname if compname else None,
            "type":         t        if t        else None,
            "country":      c        if c        else None,
            "language":     lang     if lang     else None,
            "timezone":     tz       if tz       else None,
            "keyboard":     kb       if kb       else None,
        }

    conn.close()
    return jsonify(resp), 200


# -------------------------------
# API: setcomputer
# -------------------------------
@bp.route("/setcomputer", methods=["POST"])
def api_setcomputer():
    """
    Create or partially update a computer registration.

    JSON body:
      - serial       required
      - computerName optional
      - type         optional
      - country      optional
      - language     optional
      - timezone     optional
      - keyboard     optional
    """
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"status": "error", "reason": "JSON body required"}), 400

    serial = str(data.get("serial") or "")
    norm = normalize_id(serial)
    if not norm:
        return jsonify({"status": "error", "reason": "Missing or invalid 'serial'"}), 400

    aliases = {
        "computername": ("computerName", "computername"),
        "postype":      ("type", "postype"),
        "country":      ("country",),
        "language":     ("language",),
        "timezone":     ("timezone",),
        "setkeyboard":  ("keyboard", "setkeyboard"),
    }

    updates = {}
    for column, keys in aliases.items():
        for key in keys:
            if key in data:
                value = data.get(key)
                if value is None:
                    value = ""
                if not isinstance(value, str):
                    return jsonify({"status": "error", "reason": f"'{key}' must be a string"}), 400
                updates[column] = value.strip()
                break

    if not updates:
        return jsonify({"status": "error", "reason": "No computer fields supplied"}), 400

    if "postype" in updates:
        postype = updates["postype"]
        if postype:
            canonical_postype = _canonical_type(postype)
            if not canonical_postype:
                return jsonify({"status": "error", "reason": "Unknown 'type'"}), 400
            updates["postype"] = canonical_postype
    if "country" in updates:
        updates["country"] = updates["country"].upper()
    if "language" in updates:
        updates["language"] = normalize_locale_list(updates["language"])
    if "setkeyboard" in updates:
        updates["setkeyboard"] = normalize_locale_tag(updates["setkeyboard"])

    conn = get_db()
    try:
        ensure_computer_placeholder(conn, norm)
        assignments = ", ".join(f"{column} = ?" for column in updates)
        conn.execute(
            f"""
            UPDATE newcomputer
            SET {assignments}
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?;
            """,
            (*updates.values(), norm),
        )
        conn.commit()

        row = conn.execute(
            """
            SELECT computername, postype, country, language, timezone, setkeyboard
            FROM newcomputer
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?
            LIMIT 1;
            """,
            (norm,),
        ).fetchone()
        return jsonify({
            "status":       "ok",
            "serial":       norm,
            "computerName": row["computername"] or None,
            "type":         row["postype"] or None,
            "country":      row["country"] or None,
            "language":     row["language"] or None,
            "timezone":     row["timezone"] or None,
            "keyboard":     row["setkeyboard"] or None,
        }), 200
    finally:
        conn.close()


# -------------------------------
# API: getapps  (avec filtres pays / modele)
# -------------------------------
@bp.route("/getapps", methods=["GET"])
def api_getapps():
    """
    Retourne la liste des applications pour un type donné,
    éventuellement filtrée par pays et modèle.

    Input:
      - ?type=POSTYPE             (obligatoire)
      - ?country=FR               (optionnel, code pays, ex: FR / DE / EN)
      - ?model=Virtual%20Machine  (optionnel, modèle poste)

    Règles filtrage pays:
      - Si country est vide: aucune restriction, tous les éléments du type sont renvoyés.
      - Si allowed_countries non vide  et country NE figure PAS dedans  => élément SKIP.
      - Si blocked_countries non vide  et country figure dedans          => élément SKIP.
      - Si les deux sont remplis: allowed s'applique d'abord, puis blocked override.
      - Si allowed_models non vide et model NE matche AUCUNE regex       => élément SKIP.

    Output JSON:
      {
        "applications": [
          { "name": "...", "url": "...", "order": <int>, "reboot": <bool>, "kind":"app" },
          ...
        ]
      }
    """
    type_name   = (request.args.get("type") or "").strip().upper()
    country_raw = (request.args.get("country") or "").strip().upper()
    model_raw   = (request.args.get("model") or "").strip()

    if not type_name:
        return jsonify({"error": "missing type"}), 400

    conn = get_db()
    _ensure_app_config_columns(conn)
    rows = conn.execute(
        """
        SELECT
          a.name              AS name,
          a.url               AS url,
          a.script            AS script,
          a.reboot            AS reboot,
          a.allowed_countries AS allowed_countries,
          a.blocked_countries AS blocked_countries,
          a.allowed_models    AS allowed_models,
          (ROW_NUMBER() OVER (ORDER BY pr.rowid) * 10) AS sort_order,
          'app'               AS kind
        FROM postype_relations pr
        JOIN apps a ON a.name = pr.application
        WHERE UPPER(TRIM(IFNULL(pr.postype, ''))) = ? AND TRIM(IFNULL(pr.application, '')) <> ''
        ORDER BY pr.rowid;
        """,
        (type_name,),
    ).fetchall()
    conn.close()

    def parse_codes(txt: str):
        if not txt:
            return set()
        # On accepte virgules, ; et espaces
        parts = re.split(r"[,\s;]+", txt.upper())
        return {p for p in parts if p}

    def parse_model_patterns(txt: str):
        if not txt:
            return []
        return [p.strip() for p in re.split(r"[;\r\n]+", str(txt)) if p.strip()]

    def model_matches_any(model: str, patterns) -> bool:
        if not patterns:
            return True
        if not model:
            return False
        for pattern in patterns:
            try:
                if re.search(pattern, model, re.IGNORECASE):
                    return True
            except re.error:
                continue
        return False

    apps_list = []
    for r in rows:
        name = r["name"]
        url = r["url"]
        if not (name and url):
            continue

        allowed_set = parse_codes(r["allowed_countries"])
        blocked_set = parse_codes(r["blocked_countries"])
        allowed_models = parse_model_patterns(r["allowed_models"])

        # --- Filtre pays si fourni ---
        if country_raw:
            # 1) allowed: si non vide et country pas dedans -> skip
            if allowed_set and country_raw not in allowed_set:
                continue
            # 2) blocked: si non vide et country dedans -> skip
            if blocked_set and country_raw in blocked_set:
                continue

        if allowed_models and not model_matches_any(model_raw, allowed_models):
            continue

        apps_list.append({
            "name":   name,
            "url":    url,
            "script": r["script"],
            "order":  r["sort_order"],
            "reboot": as_reboot_flag(r["reboot"]),
            "kind":   r["kind"] or "app",
        })

    return jsonify({"applications": apps_list}), 200


# -------------------------------
# API: getdrivers
# -------------------------------
@bp.route("/getdrivers", methods=["GET"])
def api_getdrivers():
    model  = request.args.get("name", default="", type=str).strip()
    osname = request.args.get("os",   default="", type=str).strip()
    conn = get_db()
    try:
        candidates = conn.execute(
            """
            SELECT model_regex, os_regex, url, bundle_id
            FROM drivers
            WHERE TRIM(COALESCE(model_regex, '')) <> ''
              AND TRIM(COALESCE(os_regex, '')) <> ''
              AND TRIM(COALESCE(url, '')) <> ''
            ORDER BY rowid;
            """
        ).fetchall()

        row = None
        for cand in candidates:
            model_pattern = (cand["model_regex"] or "").strip()
            os_pattern = (cand["os_regex"] or "").strip()
            try:
                if (
                    re.search(model_pattern, model, flags=re.IGNORECASE)
                    and re.search(os_pattern, osname, flags=re.IGNORECASE)
                ):
                    row = cand
                    break
            except re.error:
                continue

        if row is None:
            return jsonify({"name": None, "url": None}), 200

        return jsonify({
            "name": None,
            "url": normalize_url(row["url"]) or None,
            "bundle_id": (row["bundle_id"] or "").strip() or None,
        }), 200
    except Exception as exc:
        return jsonify({
            "error": "driver_lookup_failed",
            "message": str(exc),
        }), 500
    finally:
        conn.close()


# -------------------------------
# API: message (ingestion logs)
# -------------------------------
@bp.route("/message", methods=["POST"])
def api_message():
    data = request.get_json(silent=True) or {}
    raw_msg = data.get("message", "")
    if not raw_msg:
        return jsonify({"status": "error", "reason": "Missing 'message'"}), 400
    serial, text = parse_serial_and_message(raw_msg)
    conn = get_logs_db()
    ts = insert_deploy_log(conn, serial, text)
    conn.close()
    return jsonify({"status": "ok", "serial": serial, "timestamp": ts, "info": text}), 200


def _safe_headers():
    hidden = {"authorization", "cookie", "x-mcp-token"}
    out = {}
    for key, value in request.headers.items():
        out[key] = "***" if key.lower() in hidden else value
    return out


def _request_payload():
    payload = {
        "method": request.method,
        "path": request.path,
        "remote_addr": request.headers.get("X-Forwarded-For", request.remote_addr),
        "query": request.args.to_dict(flat=False),
        "headers": _safe_headers(),
        "json": None,
        "form": None,
        "raw": "",
    }

    data = request.get_json(silent=True)
    if data is not None:
        payload["json"] = data
    if request.form:
        payload["form"] = request.form.to_dict(flat=False)

    raw = request.get_data(cache=True, as_text=True) or ""
    if raw and data is None and not request.form:
        payload["raw"] = raw[:20000]
    return payload


def _first_value(value):
    if isinstance(value, list):
        return "" if not value else str(value[0] or "").strip()
    return str(value or "").strip()


def _pick_request_value(payload, *names):
    for name in names:
        if name in payload["query"]:
            value = _first_value(payload["query"].get(name))
            if value:
                return value

    json_data = payload.get("json")
    if isinstance(json_data, dict):
        for name in names:
            if name in json_data:
                value = _first_value(json_data.get(name))
                if value:
                    return value

    form_data = payload.get("form")
    if isinstance(form_data, dict):
        for name in names:
            if name in form_data:
                value = _first_value(form_data.get(name))
                if value:
                    return value

    return ""


def _append_tanium_log(log_path: str, entry: dict):
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")


def _log_tanium_request(route_name: str, log_path: str):
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    payload = _request_payload()
    serial = _pick_request_value(payload, "serial", "Serial", "SERIAL", "serialNumber", "SerialNumber")
    model = _pick_request_value(payload, "model", "Model", "MODEL", "computerModel", "ComputerModel")
    entry = {
        "timestamp": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "route": route_name,
        "serial": serial,
        "model": model,
        "request": payload,
    }
    return entry


def _find_tanium_bundle_for_model(model: str):
    model = (model or "").strip()
    if not model:
        return None

    conn = get_db()
    try:
        candidates = conn.execute(
            """
            SELECT model_regex, bundle_id
            FROM drivers
            WHERE TRIM(COALESCE(model_regex, '')) <> ''
              AND TRIM(COALESCE(bundle_id, '')) <> ''
            ORDER BY rowid;
            """
        ).fetchall()

        for cand in candidates:
            pattern = (cand["model_regex"] or "").strip()
            try:
                if re.search(pattern, model, flags=re.IGNORECASE):
                    return (cand["bundle_id"] or "").strip()
            except re.error:
                continue
    finally:
        conn.close()

    return None


def _format_tanium_bundle_id(bundle_id: str):
    bundle_id = (bundle_id or "").strip()
    if re.fullmatch(r"\d+", bundle_id):
        return int(bundle_id)
    return bundle_id


def _coerce_timeout(value, fallback=120):
    try:
        t = int(str(value).strip())
        return t if t > 0 else fallback
    except (TypeError, ValueError):
        return fallback


@bp.route("/tanium/global", methods=["GET", "POST"])
def tanium_global_webservice():
    entry = _log_tanium_request("tanium_global", TANIUM_GLOBAL_LOG)

    # Per-model bundle if defined, otherwise the global default from config.
    model_bundle = _find_tanium_bundle_for_model(entry["model"])
    default_bundle = (get_config("default_bundle_id", "") or "").strip()
    effective_bundle = model_bundle if model_bundle else default_bundle

    # Global timeout (replaces the previously hard-coded 120), always applied.
    timeout = _coerce_timeout(get_config("default_bundle_timeout", "120"))

    if effective_bundle:
        response_payload = {
            "BundleID": _format_tanium_bundle_id(effective_bundle),
            "BundleTimeout": timeout,
        }
    else:
        response_payload = {}
    entry["response"] = response_payload
    _append_tanium_log(TANIUM_GLOBAL_LOG, entry)
    return jsonify(response_payload), 200


@bp.route("/tanium/bundle", methods=["GET", "POST"])
def tanium_bundle_webservice():
    entry = _log_tanium_request("tanium_bundle", TANIUM_BUNDLE_LOG)
    response_payload = {
        "status": "ok",
        "route": "tanium_bundle",
        "timestamp": entry["timestamp"],
        "serial": entry["serial"],
        "model": entry["model"],
    }
    entry["response"] = response_payload
    _append_tanium_log(TANIUM_BUNDLE_LOG, entry)
    return jsonify(response_payload), 200
