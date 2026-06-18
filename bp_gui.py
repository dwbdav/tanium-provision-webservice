"""
bp_gui.py - GUI management blueprints

This module regroups GUI blueprints while preserving each original
module namespace. Each section is kept in its own builder function so
helpers/templates with identical names do not collide.
"""


# ========================================================================
# Computers blueprint, formerly bp_computers.py
# ========================================================================
def _build_computers_bp():
    """
    =============================================================================
    bp_computers.py - Computer/Device Management Blueprint
    =============================================================================

    Manages computer inventory and provisioning configuration.

    Features:
      - List all registered computers with search/pagination
      - View and edit computer properties (type, language, keyboard, country)
      - Track deployment progress per device
      - Map serial numbers to computer names
      - Multi-locale support
    """

    from flask import Blueprint, request, redirect, url_for, abort, session
    from core import get_db, normalize_id, collect_types, require_roles, render_inline

    # Blueprint
    bp = Blueprint("computers", __name__)

    # Types reserved for internal logic (cannot be chosen for a computer)
    RESERVED_TYPES = ("FINALIZE",)

    # Standards for dropdowns (to avoid typo-sensitive values)
    COUNTRY_CHOICES = [
        "FR", "US", "GB", "DE", "ES", "IT", "NL", "BE", "LU", "CH",
        "AT", "PT", "PL", "CZ", "SK", "SE", "NO", "DK", "FI", "IE",
        "CA", "MX", "BR", "AR", "CL", "CO", "PE", "AU", "NZ", "JP",
        "KR", "CN", "TW", "IN", "SG", "AE", "SA", "ZA", "MA", "TN",
    ]

    LANGUAGE_CHOICES = [
        "fr-FR", "en-US", "en-GB", "de-DE", "es-ES",
        "it-IT", "nl-NL", "pt-PT", "pl-PL", "cs-CZ",
    ]

    KEYBOARD_CHOICES = [
        "fr-FR", "en-US", "en-GB", "de-DE", "es-ES",
        "it-IT", "nl-NL", "pt-PT", "pl-PL", "cs-CZ",
    ]

    TIMEZONE_CHOICES = [
        "Romance Standard Time",
        "UTC",
        "GMT Standard Time",
        "W. Europe Standard Time",
        "Central Europe Standard Time",
        "Central European Standard Time",
        "Eastern Standard Time",
        "Central Standard Time",
        "Mountain Standard Time",
        "Pacific Standard Time",
        "Canada Central Standard Time",
        "Central Standard Time (Mexico)",
        "E. South America Standard Time",
        "Tokyo Standard Time",
        "China Standard Time",
        "Singapore Standard Time",
        "Arabian Standard Time",
        "AUS Eastern Standard Time",
    ]

    # --------------------------------------------------------------------
    # Helpers: locale normalization
    # --------------------------------------------------------------------
    def normalize_locale_tag(tag: str) -> str:
        """
        fr-fr  -> fr-FR
        EN-us  -> en-US
        de-DE  -> de-DE (already OK)
        other  -> returned as-is if no '-'
        """
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
        """
        "fr-fr / EN-gb / de-de" -> "fr-FR / en-GB / de-DE"
        Split on "/", trim spaces, drop empties.
        """
        if not raw:
            return ""
        parts = []
        for p in raw.split("/"):
            p_norm = normalize_locale_tag(p)
            if p_norm:
                parts.append(p_norm)
        return " / ".join(parts)


    def first_locale(raw: str) -> str:
        if not raw:
            return ""
        first = str(raw).split("/", 1)[0].strip()
        return normalize_locale_tag(first)


    def load_type_choices(conn):
        types_set = set(collect_types(conn))

        # BASE is a valid profile in deployment timeline and should be selectable.
        types_set.add("BASE")
        return sorted(
            [t for t in types_set if t and t.upper() not in ("EMPTY", "COMMON")],
            key=lambda x: x.lower(),
        )


    def ensure_choice(current: str, choices):
        cur = (current or "").strip()
        if not cur:
            return list(choices)
        out = list(choices)
        if cur not in out:
            out.append(cur)
        return out


    def short_id(value: str, start=6, end=4) -> str:
        s = (value or "").strip()
        if len(s) <= (start + end + 3):
            return s
        return f"{s[:start]}...{s[-end:]}"


    # ---------- LIST ----------
    @bp.route("/computers")
    def computers_list():
        q = request.args.get("q", "").strip()
        page_raw = request.args.get("page", "1").strip()
        try:
            page = int(page_raw)
        except ValueError:
            page = 1
        if page < 1:
            page = 1
        per_page = 50

        conn = get_db()
        where_sql = ""
        where_args = []
        if q:
            where_sql = """
            WHERE UPPER(COALESCE(nc.computername,'')) LIKE UPPER(?)
               OR UPPER(COALESCE(nc.macaddress,''))   LIKE UPPER(?)
            """
            where_args = [f"%{q}%", f"%{q}%"]

        total_rows = conn.execute(
            "SELECT COUNT(*) AS c FROM newcomputer nc " + where_sql + ";",
            where_args,
        ).fetchone()["c"]
        total_pages = max(1, (total_rows + per_page - 1) // per_page)
        if page > total_pages:
            page = total_pages
        offset = (page - 1) * per_page

        rows_db = conn.execute(
            """
            SELECT nc.macaddress,
                   nc.computername,
                   nc.postype,
                   nc.country,
                   nc.language,
                   nc.timezone,
                   nc.setkeyboard
            FROM newcomputer nc
            """
            + where_sql
            + """
            ORDER BY LOWER(COALESCE(nc.computername, '')) ASC, nc.macaddress ASC
            LIMIT ? OFFSET ?;
            """,
            where_args + [per_page, offset],
        ).fetchall()
        conn.close()

        rows = []
        for r in rows_db:
            item = {k: r[k] for k in r.keys()}
            item["serial_short"] = short_id(r["macaddress"] or "")
            cc = (r["country"] or "").strip().upper()
            item["country_display"] = cc or "-"
            lang = (r["language"] or "").strip()
            item["timezone_display"] = (r["timezone"] or "").strip() or "-"
            kbd = (r["setkeyboard"] or "").strip()
            item["locale_summary"] = " / ".join([x for x in [lang or "-", kbd or "-"] if x])
            rows.append(item)

        locale_uniform = False
        if len(rows) > 1:
            locale_values = {(row.get("locale_summary") or "").strip() for row in rows}
            locale_uniform = len(locale_values) == 1

        role = (session.get("role") or "").lower()
        can_modify = role in ("admin", "operator")

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <title>Computers</title>
    <script src="https://cdn.tailwindcss.com"></script>
    __HEAD_ASSETS__
    <style>
    :root{
      --bg:#0b1220; --panel:#121a2b; --panel-2:#0f1726;
      --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06);
      --heading:#dbe8ff; --note:#cfe1ff; --dev:#dbe8ff;
    }
    html,body{height:100%} body{background:var(--bg); color:var(--text)}
    a, a:hover{color:#b9d8ff}
    .card{background:var(--panel); border:1px solid var(--border)}
    .table{--bs-table-bg:transparent; color:var(--text)}
    .table thead th{color:var(--heading)!important; border-bottom:1px solid var(--border)}
    .table tbody tr+tr td{border-top:1px solid var(--border)}
    .table>:not(caption)>*>*{background-color:transparent}
    .table td, .table th{color:var(--text)!important}
    h1{color:var(--heading)!important}
    .subtitle{color:var(--note)}
    .device-code{
      color:var(--dev);
      font-weight:600;
      font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      font-size:12px;
      letter-spacing:.01em;
    }
    .serial-cell{display:flex; align-items:center; min-width:0}
    .serial-link{
      color:var(--dev);
      text-decoration:none;
    }
    .serial-link:hover{
      color:#7db8ff;
      text-decoration:underline;
      text-underline-offset:3px;
    }
    .computer-delete-btn{
      width:36px;
      height:36px;
      border-radius:10px;
      border:1px solid #f1c0c5;
      background:#fff0f1;
      color:#b91c1c;
      display:inline-flex;
      align-items:center;
      justify-content:center;
      cursor:pointer;
      transition:.15s ease;
      box-shadow:0 2px 8px rgba(0,0,0,.06);
    }
    .computer-delete-btn svg{
      width:16px;
      height:16px;
      stroke:currentColor;
      stroke-width:2;
      fill:none;
      stroke-linecap:round;
      stroke-linejoin:round;
    }
    .computer-delete-btn:hover{
      border-color:#e9a8af;
      background:#ffe3e6;
      color:#991b1b;
      transform:translateY(-1px);
      box-shadow:0 6px 14px rgba(0,0,0,.1);
    }
    .toolbar{display:flex; align-items:center; gap:.6rem; flex-wrap:wrap; margin-left:.75rem;}
    .toolbar .spacer{flex:1 1 auto;}
    .chip{
      display:inline-flex; align-items:center; gap:.6rem;
      background:linear-gradient(180deg,#182439,#121a2b);
      color:var(--text); border:1px solid var(--border);
      border-radius:12px; padding:.5rem .75rem; text-decoration:none;
      box-shadow:0 1px 0 rgba(0,0,0,.4), inset 0 0 0 1px rgba(255,255,255,.02);
    }
    .chip:hover{transform:translateY(-1px); border-color:#2b3d5c; box-shadow:0 6px 18px rgba(0,0,0,.35)}
    .chip .label{position:relative; top:1px}
    .modicon{
      width:36px; height:36px; border-radius:10px; display:inline-flex;
      align-items:center; justify-content:center;
      box-shadow:inset 0 0 0 1px rgba(0,0,0,.25), 0 2px 10px rgba(0,0,0,.25);
    }
    .modicon svg{width:22px; height:22px}
    .modicon svg *{stroke:#fff; stroke-width:2; fill:none; stroke-linecap:round; stroke-linejoin:round}
    .mi-home{background:#3fa7ff}
    .mi-add {background:#2bb673}
    .btn-action{
      display:inline-flex; align-items:center; justify-content:center;
      height:36px; width:44px; padding:0;
      border-radius:10px; border:0;
    }
    .actions-cell{
      display:inline-flex;
      align-items:center;
      gap:.8rem;
    }
    .btn-primary.btn-action{background:#0d6efd}
    .btn-primary.btn-action:hover{background:#0b5ed7}
    .btn-danger.btn-action{background:#dc3545}
    .btn-danger.btn-action:hover{background:#bb2d3b}
    .tag{
      display:inline-flex; align-items:center;
      padding:.15rem .45rem; border-radius:999px;
      font-size:.72rem; font-weight:600;
      color:var(--heading);
      background:rgba(255,255,255,.06);
      border:1px solid var(--border);
    }
    .status-pill{
      display:inline-flex; align-items:center; gap:.35rem;
      padding:.2rem .5rem; border-radius:999px;
      font-size:.72rem; font-weight:700;
      border:1px solid var(--border);
      justify-content:center;
    }
    .status-link{
      text-decoration:none;
    }
    .status-link:hover .status-pill{
      filter:brightness(.96);
    }
    .status-dot{
      width:.48rem;
      height:.48rem;
      border-radius:999px;
      display:inline-block;
    }
    .st-ok{
      color:#0f8a53!important;
      background:rgba(16,185,129,.14)!important;
      border-color:rgba(16,185,129,.38)!important;
    }
    .st-fail{
      color:#dc2626!important;
      background:rgba(239,68,68,.14)!important;
      border-color:rgba(239,68,68,.4)!important;
    }
    .st-warn,.st-run{
      color:#c56a00!important;
      background:rgba(245,158,11,.16)!important;
      border-color:rgba(245,158,11,.42)!important;
    }
    .st-unk{
      color:#475569!important;
      background:rgba(148,163,184,.2)!important;
      border-color:rgba(148,163,184,.42)!important;
    }
    .st-ok .status-dot{background:#10b981}
    .st-fail .status-dot{background:#ef4444}
    .st-warn .status-dot,.st-run .status-dot{background:#f59e0b}
    .st-unk .status-dot{background:#64748b}
    .locale-sub{
      color:#000;
      font-size:.78rem;
      line-height:1.25;
    }
    .timezone-cell{
      color:#0f172a;
      font-size:.78rem;
      font-weight:600;
      white-space:nowrap;
    }
    table.locale-uniform .col-locale .locale-sub,
    table.locale-uniform .col-locale{
      opacity:1;
    }
    .col-country,.col-locale{text-align:left}
    .country-code{
      font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      font-size:.8rem;
      color:#000;
    }
    .type-empty{
      color:var(--muted);
      font-style:italic;
      font-size:.82rem;
    }
    /* Search */
    .searchwrap{position:relative; min-width:260px; max-width:360px;}
    .searchbox{
      width:100%;
      height:44px;
      padding:.55rem .75rem .55rem 2.5rem;
      border-radius:.75rem;
      border:1px solid #cbd5e1;
      background:#fff;
      color:#334155;
      outline:0;
      box-shadow:0 1px 2px rgba(0,0,0,.05);
    }
    .searchbox::placeholder{color:#a8b7cf}
    .searchwrap svg{
      position:absolute; left:.75rem; top:50%; transform:translateY(-50%);
      width:18px; height:18px; opacity:.75;
    }
    .list-header{
      display:grid;
      grid-template-columns:minmax(220px,1fr) auto;
      align-items:center;
      gap:1rem;
      margin-bottom:1.5rem;
    }
    .list-header-left .page-kicker{
      margin:0;
      color:#94a3b8;
      font-size:.75rem;
      font-weight:700;
      letter-spacing:.22em;
      text-transform:uppercase;
    }
    .list-header-left h1{
      margin:.5rem 0 0;
      color:#020617!important;
      line-height:1.05;
      font-size:1.875rem;
      font-weight:800;
      letter-spacing:-.025em;
    }
    .list-header-actions{
      display:flex;
      align-items:center;
      justify-content:flex-end;
      gap:.75rem;
    }
    .list-header .searchwrap{width:26.25rem; max-width:100%; margin:0;}
    @media (max-width: 992px){
      .list-header{grid-template-columns:1fr;}
      .list-header-actions{justify-content:flex-start; flex-wrap:wrap;}
      .list-header .searchwrap{max-width:100%;}
    }
    </style>
    </head>
    <body class="min-h-screen bg-slate-50 text-slate-900">
    <div class="container-fluid">
      <main class="mx-auto max-w-[1800px] px-8 py-8">

        <div class="list-header">
          <div class="list-header-left">
            <p class="page-kicker">Administration</p>
            <h1>Computers</h1>
          </div>

          <div class="list-header-actions">
            <form class="searchwrap" method="get" action="{{ url_for('computers.computers_list') }}" role="search" onsubmit="return false;">
              <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7" stroke="currentColor" fill="none" stroke-width="2"/>
                <path d="M20 20l-3.2-3.2" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
              <input id="searchBox" name="q" class="searchbox" type="search"
                     placeholder="Search" value="{{ q or '' }}" autocomplete="off">
            </form>
            {% if can_modify %}
            <a class="btn-primary-green" href="{{ url_for('computers.computer_add') }}">+ Add</a>
            {% endif %}
          </div>
        </div>

        <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div class="max-h-[calc(100vh-190px)] overflow-auto">
              <table class="standard-list-table min-w-full table-fixed divide-y divide-slate-200{% if locale_uniform %} locale-uniform{% endif %}">
                <thead class="sticky top-0 z-10 bg-slate-100/95 backdrop-blur">
                  <tr class="text-left text-xs font-bold uppercase tracking-wide text-slate-500">
                    <th class="w-[21%] px-6 py-4">Serial</th>
                    <th class="w-[20%] px-6 py-4">Computer Name</th>
                    <th class="w-[12%] px-6 py-4">Type</th>
                    <th class="w-[7%] col-country px-6 py-4">Country</th>
                    <th class="w-[20%] px-6 py-4">Timezone</th>
                    <th class="w-[14%] col-locale px-6 py-4">Lang / Keyboard</th>
                    {% if can_modify %}<th class="w-[6%] px-6 py-4"></th>{% endif %}
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-100 bg-white text-sm">
                {% for row in rows %}
                  <tr class="data-row odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60"
                      data-serial="{{ row.macaddress }}"
                      data-name="{{ row.computername or '' }}"
                      data-type="{{ row.postype or '' }}"
                      data-country="{{ row.country or '' }}"
                      data-language="{{ row.language or '' }}"
                      data-timezone="{{ row.timezone or '' }}"
                      data-keyboard="{{ row.setkeyboard or '' }}">
                    <td class="px-6 py-3 align-middle">
                      <div class="serial-cell">
                        {% if can_modify %}
                        <a class="serial-link" href="{{ url_for('computers.computer_edit', mac=row.macaddress) }}"><code class="device-code">{{ row.macaddress }}</code></a>
                        {% else %}
                        <code class="device-code">{{ row.macaddress }}</code>
                        {% endif %}
                      </div>
                    </td>
                    <td class="px-6 py-3 align-middle"><strong>{{ row.computername or "" }}</strong></td>
                    <td class="px-6 py-3 align-middle">
                      {% set type_value = (row.postype or '')|trim %}
                      {% if not type_value or type_value|upper in ['EMPTY', 'NONE'] %}
                        <span class="type-empty">None</span>
                      {% else %}
                        <span class="tag">{{ type_value }}</span>
                      {% endif %}
                    </td>
                    <td class="col-country px-6 py-3 align-middle"><span class="country-code">{{ row.country_display }}</span></td>
                    <td class="px-6 py-3 align-middle"><span class="timezone-cell">{{ row.timezone_display }}</span></td>
                    <td class="col-locale px-6 py-3 align-middle"><div class="locale-sub">{{ row.locale_summary }}</div></td>
                    {% if can_modify %}
                    <td class="px-6 py-3 align-middle">
                      <form method="post" action="{{ url_for('computers.computer_delete', mac=row.macaddress) }}"
                            class="m-0" onsubmit="return confirm('Delete this computer?');">
                        <button class="computer-delete-btn" type="submit" title="Supprimer {{ row.macaddress }}" aria-label="Supprimer {{ row.macaddress }}">
                          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6l1-2h6l1 2"></path><path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path><path d="M14 10v6"></path></svg>
                        </button>
                      </form>
                    </td>
                    {% endif %}
                  </tr>
                {% endfor %}
                {% if rows|length == 0 %}
                  <tr><td colspan="{{ 7 if not can_modify else 8 }}" class="text-center text-muted py-4">No records</td></tr>
                {% else %}
                  <tr id="noMatch" style="display:none;">
                    <td colspan="{{ 7 if not can_modify else 8 }}" class="text-center text-muted py-4">No matching records</td></tr>
                {% endif %}
                </tbody>
              </table>
            <div class="d-flex justify-content-between align-items-center p-3">
              <div class="small text-muted">
                Showing {{ rows|length }} of {{ total_rows }} (page {{ page }} / {{ total_pages }})
              </div>
              <div class="btn-group">
                {% if page > 1 %}
                  <a class="btn btn-sm btn-outline-secondary" href="{{ url_for('computers.computers_list', q=q, page=page-1) }}">Prev</a>
                {% else %}
                  <span class="btn btn-sm btn-outline-secondary disabled">Prev</span>
                {% endif %}
                {% if page < total_pages %}
                  <a class="btn btn-sm btn-outline-secondary" href="{{ url_for('computers.computers_list', q=q, page=page+1) }}">Next</a>
                {% else %}
                  <span class="btn btn-sm btn-outline-secondary disabled">Next</span>
                {% endif %}
              </div>
            </div>
          </div>
        </section>

      </main>
    </div>

    <script>
    (function(){
      const input   = document.getElementById('searchBox');
      const rows    = Array.from(document.querySelectorAll('tbody tr.data-row'));
      const noMatch = document.getElementById('noMatch');

      function doFilter(){
        const q = (input.value || '').trim().toLowerCase();
        let shown = 0;
        for (const tr of rows){
          const hay = (
            (tr.dataset.serial || '') + ' ' +
            (tr.dataset.name || '') + ' ' +
            (tr.dataset.type || '') + ' ' +
            (tr.dataset.country || '') + ' ' +
            (tr.dataset.language || '') + ' ' +
            (tr.dataset.timezone || '') + ' ' +
            (tr.dataset.keyboard || '')
          ).toLowerCase();
          const ok  = !q || hay.indexOf(q) !== -1;
          tr.style.display = ok ? '' : 'none';
          if (ok) shown++;
        }
        if (noMatch) noMatch.style.display = shown ? 'none' : '';
        const url = new URL(window.location);
        if (q) url.searchParams.set('q', input.value);
        else   url.searchParams.delete('q');
        history.replaceState(null, '', url);
      }

      let t; input.addEventListener('input', () => { clearTimeout(t); t = setTimeout(doFilter, 80); });
      doFilter();
    })();
    </script>

    </body>
    </html>
    """
        return render_inline(
            tmpl,
            rows=rows,
            q=q,
            can_modify=can_modify,
            locale_uniform=locale_uniform,
            page=page,
            total_pages=total_pages,
            total_rows=total_rows,
        )


    # ---------- ADD ----------
    @bp.route("/computers/add", methods=["GET", "POST"])
    @require_roles('admin', 'operator')
    def computer_add():
        if request.method == "POST":
            serial_raw   = request.form.get("serial", "").strip() or request.form.get("macaddress", "").strip()
            computername = request.form.get("computername", "").strip()
            sel_type     = request.form.get("type_select", "").strip().upper()

            # No creation here + forbid reserved types
            if sel_type.upper() in RESERVED_TYPES:
                abort(400, "reserved type")

            country_raw  = request.form.get("country", "").strip()
            language_raw = request.form.get("language", "").strip()
            timezone_raw = request.form.get("timezone", "").strip()
            kbd_raw      = request.form.get("setkeyboard", "").strip()

            country  = country_raw.upper() if country_raw else ""
            language = normalize_locale_list(language_raw)
            timezone = timezone_raw
            setkbd   = normalize_locale_tag(kbd_raw)
            if not setkbd:
                abort(400, "missing keyboard")

            norm_id = normalize_id(serial_raw)
            if not norm_id:
                abort(400, "invalid serial")

            conn = get_db()
            conn.execute(
                """
                DELETE FROM newcomputer
                WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':', ''), '-', ''), ' ', '')) = ?;
                """,
                (norm_id,),
            )
            conn.execute(
                """
                INSERT INTO newcomputer (macaddress, computername, postype, country, language, timezone, setkeyboard)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                (norm_id, computername, sel_type, country, language, timezone, setkbd),
            )
            conn.commit(); conn.close()
            return redirect(url_for("computers.computers_list"))

        conn = get_db()
        type_choices = load_type_choices(conn)
        conn.close()

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <title>Add Computer</title>
    __HEAD_ASSETS__
    <style>
    :root{
      --bg:#0b1220; --panel:#121a2b; --panel-2:#0f1726;
      --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06);
      --heading:#dbe8ff; --focus:#3fa7ff;
    }
    body{background:var(--bg); color:var(--text)}
    .card{background:var(--panel); border:1px solid var(--border)}
    h1{color:var(--heading)!important}
    .form-label{color:var(--heading); font-weight:700}
    .form-control,.form-select{
      background:var(--panel-2)!important;
      color:var(--text)!important;
      border:1px solid rgba(255,255,255,.18)!important;
      border-radius:12px!important;
      min-height:44px;
      box-shadow:inset 0 1px 1px rgba(0,0,0,.35);
    }
    .form-control::placeholder{color:#a8b7cf; opacity:1}
    .form-control:focus,.form-select:focus{
      border-color:var(--focus)!important;
      box-shadow:0 0 0 .2rem rgba(63,167,255,.25)!important;
    }
    .form-text{color:var(--muted)}
    </style>
    </head>
    <body class="p-4">
    <div class="container-fluid">

      <h1 class="mb-4">Add / Update Computer</h1>

      <form method="post" class="card shadow-sm p-3">
        <div class="mb-3">
          <label class="form-label">Serial (key)</label>
          <input type="text" class="form-control" name="serial" required placeholder="CNU1234ABC">
          <div class="form-text">Unique identifier (e.g., BIOS serial)</div>
        </div>

        <div class="mb-3">
          <label class="form-label">Computer Name</label>
          <input type="text" class="form-control" name="computername" required placeholder="INC-123456">
        </div>

        <div class="mb-3">
          <label class="form-label">Type</label>
          <select class="form-select" name="type_select">
            <option value="">None</option>
            {% for tp in type_choices %}
              {% if tp.upper() in reserved_types %}
                <option value="{{ tp }}" disabled>{{ tp }} (reserved)</option>
              {% else %}
                <option value="{{ tp }}">{{ tp }}</option>
              {% endif %}
            {% endfor %}
          </select>
        </div>

        <div class="mb-3">
          <label class="form-label">Country</label>
          <select class="form-select" name="country">
            <option value="">None</option>
            {% for cc in country_choices %}
              <option value="{{ cc }}">{{ cc }}</option>
            {% endfor %}
          </select>
          <div class="form-text">ISO country code, used for apps / keyboard / language rules.</div>
        </div>

        <div class="mb-3">
          <label class="form-label">Language</label>
          <select class="form-select" name="language">
            <option value="">None</option>
            {% for lang in language_choices %}
              <option value="{{ lang }}">{{ lang }}</option>
            {% endfor %}
          </select>
          <div class="form-text">Windows UI language (locale).</div>
        </div>

        <div class="mb-3">
          <label class="form-label">Timezone</label>
          <select class="form-select" name="timezone">
            <option value="">None</option>
            {% for tz in timezone_choices %}
              <option value="{{ tz }}" {% if tz == 'Romance Standard Time' %}selected{% endif %}>{{ tz }}</option>
            {% endfor %}
          </select>
          <div class="form-text">Windows time zone identifier used during provisioning.</div>
        </div>

        <div class="mb-3">
          <label class="form-label">Keyboard / Locale</label>
          <select class="form-select" name="setkeyboard" required>
            <option value="">Select keyboard locale...</option>
            {% for kbd in keyboard_choices %}
              <option value="{{ kbd }}">{{ kbd }}</option>
            {% endfor %}
          </select>
          <div class="form-text">Used for unattend.xml and input locales.</div>
        </div>

        <div class="d-flex gap-2">
          <button class="btn btn-success" type="submit">Save</button>
          <a class="btn btn-secondary" href="{{ url_for('computers.computers_list') }}">Cancel</a>
        </div>
      </form>

    </div>
    </body>
    </html>
    """
        return render_inline(
            tmpl,
            type_choices=type_choices,
            reserved_types=RESERVED_TYPES,
            country_choices=COUNTRY_CHOICES,
            language_choices=LANGUAGE_CHOICES,
            keyboard_choices=KEYBOARD_CHOICES,
            timezone_choices=TIMEZONE_CHOICES,
        )


    # ---------- EDIT ----------
    @bp.route("/computers/<mac>/edit", methods=["GET", "POST"])
    @require_roles('admin', 'operator')
    def computer_edit(mac):
        norm_id = normalize_id(mac)
        if not norm_id:
            abort(400, "invalid id")

        conn = get_db()

        if request.method == "POST":
            new_name = request.form.get("computername", "").strip()
            sel_type = request.form.get("type_select", "").strip().upper()

            # Cannot select reserved types from this screen
            if sel_type.upper() in RESERVED_TYPES:
                conn.close()
                abort(400, "reserved type")

            country_raw  = request.form.get("country", "").strip()
            language_raw = request.form.get("language", "").strip()
            timezone_raw = request.form.get("timezone", "").strip()
            kbd_raw      = request.form.get("setkeyboard", "").strip()

            new_country  = country_raw.upper() if country_raw else ""
            new_language = normalize_locale_list(language_raw)
            new_timezone = timezone_raw
            new_keyboard = normalize_locale_tag(kbd_raw)
            if not new_keyboard:
                conn.close()
                abort(400, "missing keyboard")

            conn.execute(
                """
                UPDATE newcomputer
                SET computername = ?, postype = ?, country = ?, language = ?, timezone = ?, setkeyboard = ?
                WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':', ''), '-', ''), ' ', '')) = ?
                """,
                (new_name, sel_type, new_country, new_language, new_timezone, new_keyboard, norm_id),
            )
            conn.commit()
            conn.close()
            return redirect(url_for("computers.computers_list"))

        row = conn.execute(
            """
            SELECT macaddress, computername, postype, country, language, timezone, setkeyboard
            FROM newcomputer
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?
            LIMIT 1;
            """,
            (norm_id,),
        ).fetchone()

        if row is None:
            conn.close()
            abort(404, "machine not found")

        type_choices = load_type_choices(conn)
        selected_country = (row["country"] or "").strip().upper()
        selected_language = first_locale(row["language"] or "")
        selected_timezone = (row["timezone"] or "").strip()
        selected_keyboard = normalize_locale_tag(row["setkeyboard"] or "")
        country_choices = ensure_choice(selected_country, COUNTRY_CHOICES)
        language_choices = ensure_choice(selected_language, LANGUAGE_CHOICES)
        timezone_choices = ensure_choice(selected_timezone, TIMEZONE_CHOICES)
        keyboard_choices = ensure_choice(selected_keyboard, KEYBOARD_CHOICES)
        conn.close()

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <title>Edit Computer</title>
    __HEAD_ASSETS__
    <style>
    :root{
      --bg:#0b1220; --panel:#121a2b; --panel-2:#0f1726;
      --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06);
      --heading:#dbe8ff; --focus:#3fa7ff;
    }
    body{background:var(--bg); color:var(--text)}
    .card{background:var(--panel); border:1px solid var(--border)}
    h1{color:var(--heading)!important}
    .form-label{color:var(--heading); font-weight:700}
    .form-control,.form-select{
      background:var(--panel-2)!important;
      color:var(--text)!important;
      border:1px solid rgba(255,255,255,.18)!important;
      border-radius:12px!important;
      min-height:44px;
      box-shadow:inset 0 1px 1px rgba(0,0,0,.35);
    }
    .form-control::placeholder{color:#a8b7cf; opacity:1}
    .form-control:focus,.form-select:focus{
      border-color:var(--focus)!important;
      box-shadow:0 0 0 .2rem rgba(63,167,255,.25)!important;
    }
    .form-text{color:var(--muted)}
    code{color:#b9d8ff}
    .readonly-key{
      background:#e8edf3!important;
      color:#5c6f82!important;
      border:1px solid #c8d4e0!important;
      cursor:not-allowed!important;
      pointer-events:none;
    }
    </style>
    </head>
    <body class="p-4">
    <div class="container-fluid">

      <h1 class="mb-4">Edit Computer</h1>

      <form method="post" class="card shadow-sm p-3">
        <div class="mb-3">
          <label class="form-label">Serial (key)</label>
          <input type="text" class="form-control readonly-key" value="{{ row.macaddress }}" readonly tabindex="-1">
          <div class="form-text">Unique identifier in DB</div>
        </div>

        <div class="mb-3">
          <label for="computername" class="form-label">Computer Name</label>
          <input type="text" id="computername" name="computername" class="form-control"
                 value="{{ row.computername or '' }}" placeholder="INC-123456" required>
        </div>

        <div class="mb-3">
          <label class="form-label">Type</label>
          <select class="form-select" name="type_select">
            <option value="" {% if not row.postype %}selected{% endif %}>None</option>
            {% for tp in type_choices %}
              {% if tp.upper() in reserved_types %}
                <option value="{{ tp }}" disabled {% if row.postype == tp %}selected{% endif %}>
                  {{ tp }} (reserved)
                </option>
              {% else %}
                <option value="{{ tp }}" {% if row.postype == tp %}selected{% endif %}>{{ tp }}</option>
              {% endif %}
            {% endfor %}
          </select>
        </div>

        <div class="mb-3">
          <label class="form-label">Country</label>
          <select class="form-select" name="country">
            <option value="" {% if not selected_country %}selected{% endif %}>None</option>
            {% for cc in country_choices %}
              <option value="{{ cc }}" {% if selected_country == cc %}selected{% endif %}>{{ cc }}</option>
            {% endfor %}
          </select>
        </div>

        <div class="mb-3">
          <label class="form-label">Language</label>
          <select class="form-select" name="language">
            <option value="" {% if not selected_language %}selected{% endif %}>None</option>
            {% for lang in language_choices %}
              <option value="{{ lang }}" {% if selected_language == lang %}selected{% endif %}>{{ lang }}</option>
            {% endfor %}
          </select>
        </div>

        <div class="mb-3">
          <label class="form-label">Timezone</label>
          <select class="form-select" name="timezone">
            <option value="" {% if not selected_timezone %}selected{% endif %}>None</option>
            {% for tz in timezone_choices %}
              <option value="{{ tz }}" {% if selected_timezone == tz %}selected{% endif %}>{{ tz }}</option>
            {% endfor %}
          </select>
        </div>

        <div class="mb-3">
          <label for="setkeyboard" class="form-label">Keyboard / Locale</label>
          <select id="setkeyboard" name="setkeyboard" class="form-select" required>
            <option value="" {% if not selected_keyboard %}selected{% endif %}>Select keyboard locale...</option>
            {% for kbd in keyboard_choices %}
              <option value="{{ kbd }}" {% if selected_keyboard == kbd %}selected{% endif %}>{{ kbd }}</option>
            {% endfor %}
          </select>
        </div>

        <div class="d-flex gap-2">
          <button class="btn btn-primary" type="submit">Save</button>
          <a class="btn btn-secondary" href="{{ url_for('computers.computers_list') }}">Cancel</a>
        </div>
      </form>

    </div>
    </body>
    </html>
    """
        return render_inline(
            tmpl,
            row=row,
            type_choices=type_choices,
            reserved_types=RESERVED_TYPES,
            country_choices=country_choices,
            language_choices=language_choices,
            keyboard_choices=keyboard_choices,
            timezone_choices=timezone_choices,
            selected_country=selected_country,
            selected_language=selected_language,
            selected_timezone=selected_timezone,
            selected_keyboard=selected_keyboard,
        )


    # ---------- DELETE ----------
    @bp.route("/computers/<mac>/delete", methods=["POST"])
    @require_roles('admin', 'operator')
    def computer_delete(mac):
        norm_id = normalize_id(mac)
        if not norm_id:
            abort(400, "invalid id")
        conn = get_db()
        conn.execute(
            """
            DELETE FROM newcomputer
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?;
            """,
            (norm_id,),
        )
        conn.commit()
        conn.close()
        return redirect(url_for("computers.computers_list"))

    return bp


computers_bp = _build_computers_bp()
del _build_computers_bp


# ========================================================================
# Drivers blueprint, formerly bp_drivers.py
# ========================================================================
def _build_drivers_bp():
    """
    =============================================================================
    bp_drivers.py - Driver Management Blueprint
    =============================================================================

    Manages driver package mappings.

    Features:
      - List driver mappings by OS and model
      - Display driver package URLs
      - Regex-based model matching support
      - Device compatibility mapping
    """

    import re
    from flask import Blueprint, request, redirect, url_for, abort, session
    from core import get_db, require_roles, render_inline, get_config, set_config
    from core import decode_display_text

    bp = Blueprint("drivers", __name__)


    # =========================
    # LIST
    # =========================
    @bp.route("/drivers")
    def drivers_list():
        conn = get_db()
        try:
            rows = conn.execute(
                """
                SELECT
                  model_regex AS model,
                  os_regex AS osname,
                  url,
                  bundle_id
                FROM drivers
                ORDER BY rowid;
                """
            ).fetchall()
        finally:
            conn.close()

        groups = {}
        driver_rows = []
        for r in rows:
            model = (r["model"] or "").strip()
            normalized = {
                "model": model,
                "display_model": decode_display_text(model) or model,
                "osname": (r["osname"] or "").strip(),
                "display_osname": decode_display_text((r["osname"] or "").strip()) or (r["osname"] or "").strip(),
                "url": (r["url"] or "").strip(),
                "bundle_id": (r["bundle_id"] or "").strip(),
                "display_file": (r["url"] or "").strip(),
            }
            normalized["model"] = normalized["model"] or model
            normalized["has_url"] = bool(normalized["url"])
            normalized["is_placeholder"] = (not normalized["url"])
            normalized["search"] = " ".join([
                normalized["model"] or "",
                normalized["display_model"] or "",
                normalized["osname"] or "",
                normalized["display_osname"] or "",
                normalized["url"] or "",
                normalized["display_file"] or "",
                normalized["bundle_id"] or "",
                "regex",
            ]).lower()
            groups.setdefault(model, []).append(normalized)
            driver_rows.append(normalized)

        model_cards = []
        for model, items in sorted(
            groups.items(),
            key=lambda x: ((x[0] or "").lower()),
        ):
            parts = [model, decode_display_text(model) or model, "regex"]
            for it in items:
                parts.extend([
                    it["osname"] or "",
                    it["display_osname"] or "",
                    it["url"] or "",
                    it["display_file"] or "",
                    it["bundle_id"] or "",
                ])
            search_blob = " ".join(parts).lower()
            upper_model = (model or "").upper()
            is_virtual = ("VIRTUAL" in upper_model) or ("HYPER-V" in upper_model) or ("VM" in upper_model)
            model_cards.append({
                "model": model or "(no model)",
                "display_model": decode_display_text(model) or model or "(no model)",
                "packs": items,
                "search": search_blob,
                "is_virtual": is_virtual,
                "can_expand": len(items) >= 3,
                "has_url": any(it["has_url"] for it in items),
                "has_missing_url": any(not it["has_url"] for it in items),
                "has_placeholder": any(it["is_placeholder"] for it in items),
            })

        role = (session.get("role") or "").lower()
        can_modify = role in ("admin", "operator")
        cfg_bundle_id = get_config("default_bundle_id", "")
        cfg_bundle_timeout = get_config("default_bundle_timeout", "120")
        total_models = len(model_cards)
        total_packs = sum(len(c["packs"]) for c in model_cards)
        ready_pack_count = sum(1 for c in model_cards for p in c["packs"] if p["has_url"])
        no_url_count = sum(1 for c in model_cards for p in c["packs"] if not p["has_url"])
        placeholder_count = sum(1 for c in model_cards for p in c["packs"] if p["is_placeholder"])

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Model</title>
      <script src="https://cdn.tailwindcss.com"></script>
    __HEAD_ASSETS__
      <style>
        :root{
          --bg:#f3f7fb;
          --panel:#ffffff;
          --panel-2:#f8fbff;
          --text:#102a43;
          --muted:#60758b;
          --border:#d7e3ef;
          --heading:#0f2942;
          --link:#0f766e;
          --warn:#8a5a00;
          --warn-bg:#fff3cd;
        }
        html,body{height:100%}
        body{
          background:
            radial-gradient(1200px 420px at 8% -18%, rgba(15,118,110,.12), transparent 56%),
            radial-gradient(1200px 420px at 95% -25%, rgba(245,158,11,.10), transparent 60%),
            var(--bg);
          color:var(--text);
          font-family:"Avenir Next","Trebuchet MS","Segoe UI",sans-serif;
        }
        a{color:var(--link); text-decoration:none}
        a:hover{text-decoration:underline}
        h1{color:var(--heading)!important}
        .drivers-header{
          margin-bottom:1.5rem;
        }
        .page-title{
          margin:.5rem 0 0;
          color:#020617!important;
          line-height:1.05;
          font-size:1.875rem;
          font-weight:800;
          letter-spacing:-.025em;
        }
        .page-kicker{
          margin:0;
          color:#94a3b8;
          font-size:.75rem;
          font-weight:700;
          letter-spacing:.22em;
          text-transform:uppercase;
        }
        .page-breadcrumb-inline{
          display:none !important;
        }

        .card{background:var(--panel); border:1px solid var(--border)}

        /* table compacte */
        .table{
          --bs-table-bg:transparent;
          color:var(--text);
          font-size:.82rem;
        }
        .table thead th{
          color:var(--heading)!important;
          border-bottom:2px solid rgba(219,232,255,.5);
          font-size:.78rem;
          text-transform:uppercase;
          letter-spacing:.06em;
          padding:.4rem .5rem;
          white-space:nowrap;
        }
        .table td, .table th{
          color:var(--text)!important;
          padding:.35rem .5rem;
        }
        .table>:not(caption)>*>*{
          background-color:transparent;
          border-bottom:0 !important;
        }
        .table tbody tr td{
          border-top:1px solid var(--border);
        }

        .drv-model{
          font-weight:600;
          font-size:.9rem;
        }
        .driver-name-link{
          color:#0f172a;
          text-decoration:none;
        }
        .driver-name-link:hover{
          color:#0f5d92;
          text-decoration:underline;
          text-underline-offset:3px;
        }
        .driver-delete-btn{
          width:36px;
          height:36px;
          border-radius:10px;
          border:1px solid #f1c0c5;
          background:#fff0f1;
          color:#b91c1c;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
        }
        .driver-delete-btn svg{
          width:16px;
          height:16px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .driver-delete-btn:hover{
          border-color:#e9a8af;
          background:#ffe3e6;
          color:#991b1b;
          transform:translateY(-1px);
          box-shadow:0 6px 14px rgba(0,0,0,.1);
        }
        .drv-meta{
          font-size:.75rem;
          color:var(--muted);
        }

        .url-cell{max-width:420px;}
        .url-text{
          display:block;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
          font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
          font-size:.78rem;
          color:var(--muted);
        }
        .model-grid{
          display:grid;
          grid-template-columns:minmax(0, 1fr);
          gap:18px;
        }
        .model-card{
          background:var(--panel);
          border:1px solid var(--border);
          border-left:4px solid #0f766e;
          border-radius:16px;
          padding:22px 24px;
          box-shadow:0 8px 22px rgba(16,42,67,.06);
        }
        .model-head{
          display:flex;
          align-items:flex-start;
          justify-content:space-between;
          gap:.8rem;
          margin-bottom:.85rem;
        }
        .model-main{
          display:flex;
          align-items:flex-start;
          gap:.55rem;
        }
        .model-icon{
          width:1.25rem;
          height:1.25rem;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          font-size:1rem;
          line-height:1;
          flex:0 0 auto;
          margin-top:.08rem;
        }
        .model-title{
          font-weight:700;
          color:var(--heading);
          font-size:1.18rem;
          margin-bottom:.15rem;
        }
        .regex-title{display:flex; align-items:center; gap:.45rem; margin-bottom:.35rem}
        .regex-badge{
          display:inline-flex;
          align-items:center;
          letter-spacing:.04em;
        }
        .model-meta{
          color:var(--muted);
          font-size:.82rem;
          margin-bottom:.4rem;
        }
        .os-pill{
          display:inline-flex;
          align-items:center;
          padding:.1rem .45rem;
          border-radius:999px;
          font-size:.7rem;
          font-weight:700;
          background:#eef5fb;
          border:1px solid var(--border);
          color:#24435f;
          white-space:nowrap;
        }
        .alt-rx{
          display:block;
          margin-top:.32rem;
          color:#6b4e00;
          font-size:.74rem;
          font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
          background:#fff5e8;
          border:1px solid #f2d5a8;
          border-radius:8px;
          padding:.12rem .45rem;
          word-break:break-all;
        }
        .pack-row{
          display:grid;
          grid-template-columns:minmax(0, 1fr) auto;
          gap:1rem;
          align-items:flex-start;
          padding:.85rem .95rem;
          border:1px solid #e4edf5;
          border-radius:12px;
          background:#fcfdff;
        }
        .pack-info{
          display:flex;
          flex-direction:column;
          gap:.25rem;
          min-width:0;
        }
        .pack-info .os-pill{
          align-self:flex-start;
        }
        .pack-head{
          display:flex;
          align-items:flex-start;
          justify-content:space-between;
          gap:1rem;
          width:100%;
        }
        .pack-name-wrap{
          min-width:0;
          display:flex;
          flex-direction:column;
          gap:.28rem;
        }
        .pack-name{line-height:1.2}
        .pack-row:first-of-type{border-top:1px solid #e4edf5}
        .pack-name{
          color:var(--text);
          font-weight:800;
          font-size:1.04rem;
          word-break:break-word;
        }
        .pack-url-line{min-width:0}
        .pack-url-line .url-text{font-size:.76rem}
        .url-actions{
          display:flex;
          align-items:center;
          gap:0;
          flex-wrap:wrap;
          justify-content:flex-end;
          flex:0 0 auto;
        }
        .url-mini-btn{
          height:26px;
          margin-left:4px;
          margin-right:4px;
          border-radius:8px;
          padding:.12rem .5rem;
          font-size:.73rem;
          border:1px solid var(--border);
          color:#1f4a6d;
          background:#ffffff;
          text-decoration:none;
          display:inline-flex;
          align-items:center;
          justify-content:center;
        }
        .url-mini-btn:hover{
          border-color:#99b1c8;
          background:#f2f8ff;
          color:#143552;
          text-decoration:none;
        }
        .url-mini-btn.copy-ok{
          border-color:rgba(55,214,122,.45);
          background:rgba(55,214,122,.16);
          color:#8ef0b8;
        }
        .url-check-result{
          font-size:.72rem;
          font-weight:700;
          color:var(--muted);
          min-height:1rem;
          display:inline-flex;
          align-items:center;
        }
        .url-check-result.ok{color:#53e39b}
        .url-check-result.ko{color:#ff7b7b}
        .url-check-result.pending{color:#ffcc66}
        .pack-actions{
          display:flex;
          gap:0;
          justify-content:flex-end;
          align-items:center;
        }
        .expand-btn{
          min-width:86px;
          height:30px;
          border-radius:8px;
          border:1px solid #9eb6cd;
          color:#214a70;
          background:#f0f7ff;
          font-size:.78rem;
          font-weight:600;
          padding:0 .7rem;
        }
        .expand-btn:hover{
          background:#e6f2ff;
          border-color:#86a5c5;
          color:#123654;
        }
        .expand-btn:focus{
          box-shadow:0 0 0 .2rem rgba(63,167,255,.25);
        }
        .tech-only{
          display:flex;
          gap:.45rem;
          align-items:center;
          flex-wrap:wrap;
          margin-top:.28rem;
          max-height:60px;
          opacity:1;
        }
        .drv-id{
          display:inline-block;
          padding:.08rem .45rem;
          border-radius:999px;
          font-size:.69rem;
          color:var(--muted);
          border:1px solid var(--border);
          background:#f4f8fc;
          font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        }
        .drv-id-missing{
          border-color:#f0cc8d;
          background:var(--warn-bg);
          color:var(--warn);
        }

        /* Toolbar + chips */
        .toolbar{
          display:flex;
          align-items:center;
          gap:.6rem;
          flex-wrap:wrap;
          margin-left:.75rem;
        }
        .toolbar .spacer{flex:1 1 auto;}
        .chip{
          display:inline-flex;
          align-items:center;
          gap:.6rem;
          color:#24435f;
          border:1px solid #cfd9e4;
          border-radius:12px;
          padding:.5rem .75rem;
          text-decoration:none;
          transition:.15s ease;
        }
        .chip:hover{
          transform:translateY(-1px);
          text-decoration:none;
        }
        .chip-nav{
          background:#ffffff;
          color:#24435f;
          border-color:#d1d5db;
          box-shadow:0 1px 3px rgba(0,0,0,.07);
        }
        .chip-nav:hover{
          border-color:#94a3b8;
          box-shadow:0 4px 10px rgba(0,0,0,.1);
          color:#1e293b;
        }
        .chip-action{
          padding:.42rem .8rem;
          gap:.5rem;
          color:#fff;
          border-radius:8px;
          border:1px solid transparent;
          box-shadow:0 2px 8px rgba(0,0,0,.12);
          font-weight:600;
        }
        .chip-action:hover{
          box-shadow:0 5px 12px rgba(0,0,0,.14);
          color:#fff;
        }
        .chip-add{
          justify-self:end;
          box-shadow:none;
        }
        .chip-logs{background:#f59e0b}
        .chip-danger{background:#ef4444}
        .modicon{
          width:36px;
          height:36px;
          border-radius:10px;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          box-shadow:none;
        }
        .modicon svg{width:22px; height:22px}
        .modicon svg *{
          stroke:#3b82f6;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .chip-nav .modicon{
          background:#ffffff;
          border:1px solid #dbe3ec;
          box-shadow:inset 0 0 0 1px rgba(255,255,255,.5);
        }
        .chip-action .modicon{
          width:22px;
          height:22px;
          border-radius:6px;
          background:rgba(255,255,255,.18);
          border:1px solid rgba(255,255,255,.25);
        }
        .chip-action .modicon svg *{stroke:#fff}
        .chip-add .modicon.mi-add{
          background:#2bb673;
          border:0;
          box-shadow:none;
        }
        .chip-add .modicon svg{
          width:22px;
          height:22px;
        }
        .chip-add .modicon svg *{
          stroke:#fff;
        }
        .chip-add .label{
          position:relative;
          top:1px;
          font-weight:500;
          letter-spacing:0;
        }

        .btn-action{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          height:30px;
          min-width:70px;
          padding:0 .7rem;
          margin-left:4px;
          margin-right:4px;
          border-radius:8px;
          border:0;
          font-size:.78rem;
        }
        .btn-primary.btn-action{
          background:#e7f1ff;
          color:#0b5ed7;
          border:1px solid #b6d4fe;
        }
        .btn-primary.btn-action:hover{
          background:#d7eaff;
          color:#084298;
          border-color:#9ec5fe;
        }
        .btn-danger.btn-action{
          background:#dc3545;
          color:#ffffff;
          border:1px solid #dc3545;
        }
        .btn-danger.btn-action:hover{
          background:#bb2d3b;
          color:#ffffff;
          border-color:#bb2d3b;
        }

        /* search box: same component as Computers */
        .searchwrap{position:relative; min-width:260px; max-width:360px;}
        .header-search{
          width:20rem;
          max-width:100%;
          min-width:0;
        }
        .searchbox{
          width:100%;
          height:44px;
          padding:.55rem .75rem .55rem 2.5rem;
          border-radius:.75rem;
          border:1px solid #cbd5e1;
          background:#fff; color:var(--text); outline:0;
        }
        .searchbox::placeholder{color:#8fa3b8}
        .searchbox:focus{
          border-color:#0f766e;
          box-shadow:0 0 0 .2rem rgba(15,118,110,.15);
        }
        .searchwrap svg{
          position:absolute; left:.6rem; top:50%; transform:translateY(-50%);
          width:18px; height:18px; opacity:.8;
        }
        .summary-grid{
          display:grid;
          grid-template-columns:repeat(4, minmax(120px, 1fr));
          gap:.6rem;
          margin:.15rem 0 .8rem;
        }
        .summary-card{
          border:1px solid var(--border);
          border-radius:12px;
          background:#fff;
          padding:.5rem .65rem;
          box-shadow:0 5px 14px rgba(16,42,67,.05);
          cursor:pointer;
          transition:transform .16s ease, box-shadow .16s ease, border-color .16s ease, background .16s ease;
          user-select:none;
        }
        .summary-card:hover{
          transform:translateY(-2px);
          border-color:#8eb4d6;
          box-shadow:0 10px 20px rgba(16,42,67,.12);
          background:#f9fcff;
        }
        .summary-card:focus-visible{
          outline:0;
          box-shadow:0 0 0 .2rem rgba(15,118,110,.18);
          border-color:#0f766e;
        }
        .summary-card.is-active{
          border-color:#0f766e;
          background:linear-gradient(180deg, #f5fffd, #edf9f6);
          box-shadow:0 12px 26px rgba(15,118,110,.14);
        }
        .summary-label{
          color:var(--muted);
          font-size:.72rem;
          text-transform:uppercase;
          letter-spacing:.04em;
          font-weight:700;
          display:block;
        }
        .summary-value{
          color:#0f2942;
          font-weight:800;
          font-size:1.07rem;
        }
        .summary-hint{
          display:block;
          color:#7a8ea3;
          font-size:.72rem;
          margin-top:.12rem;
        }
        .no-url-text{
          color:var(--warn);
          background:var(--warn-bg);
          border:1px solid #f0cc8d;
          border-radius:8px;
          display:inline-block;
          padding:.08rem .45rem;
          font-size:.72rem;
          font-weight:700;
        }
        @media (max-width: 1100px){
          .summary-grid{grid-template-columns:repeat(2, minmax(120px, 1fr))}
        }
        @media (max-width: 900px){
          .drivers-header{
            grid-template-columns:1fr;
            gap:.75rem;
          }
          .header-search{
            justify-self:stretch;
          }
          .pack-row{grid-template-columns:1fr}
          .pack-head{flex-direction:column}
          .url-actions{justify-content:flex-start}
          .pack-actions{justify-content:flex-start}
        }
      </style>
    </head>
    <body class="p-3">
      <div class="container-fluid">
      <main class="mx-auto max-w-[1800px] px-8 py-8">

        <div class="drivers-header mb-6 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <p class="page-kicker">Administration</p>
            <h1 class="page-title">Model</h1>
          </div>

          <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
            <form class="searchwrap header-search" method="get" action="{{ url_for('drivers.drivers_list') }}" role="search" onsubmit="return false;">
              <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7" stroke="currentColor" fill="none" stroke-width="2"/>
                <path d="M20 20l-3.2-3.2" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
              <input id="drv-search" name="q" class="searchbox" type="search"
                     placeholder="Search model, OS, package or URL" value="" autocomplete="off">
            </form>

            {% if can_modify %}
            <a class="btn-primary-green" href="{{ url_for('drivers.driver_add') }}">+ Add</a>
            {% endif %}
          </div>
        </div>

        {% if can_modify %}
        <form method="post" action="{{ url_for('drivers.drivers_config') }}"
              class="mb-2 rounded-2xl border border-slate-200 bg-white shadow-sm px-6 py-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:gap-4">
          <div class="flex-1">
            <label class="block text-xs font-bold uppercase tracking-wide text-slate-500 mb-1">Default Bundle ID</label>
            <input type="text" name="default_bundle_id" value="{{ cfg_bundle_id }}"
                   placeholder="sent when a model has no bundle"
                   class="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm">
          </div>
          <div class="w-full sm:w-44">
            <label class="block text-xs font-bold uppercase tracking-wide text-slate-500 mb-1">Default Timeout (s)</label>
            <input type="number" min="1" name="default_bundle_timeout" value="{{ cfg_bundle_timeout }}"
                   class="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm">
          </div>
          <button type="submit" class="btn-primary-green">Save defaults</button>
        </form>
        <p class="mb-6 text-xs text-slate-400">Tanium global defaults — the Bundle ID is sent when a model has no specific bundle; the Timeout always applies.</p>
        {% endif %}

        <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div class="max-h-[calc(100vh-190px)] overflow-auto">
            <table id="drivers-table" class="standard-list-table min-w-full table-fixed divide-y divide-slate-200">
              <thead class="sticky top-0 z-10 bg-slate-100/95 backdrop-blur">
                <tr class="text-left text-xs font-bold uppercase tracking-wide text-slate-500">
                  <th class="w-[58%] px-6 py-4">Model Regex</th>
                  <th class="w-[24%] px-6 py-4">OS Regex</th>
                  <th class="w-[10%] px-6 py-4">Bundle ID</th>
                  {% if can_modify %}<th class="w-[8%] px-6 py-4 text-right"></th>{% endif %}
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-100 bg-white text-sm">
              {% for row in driver_rows %}
                <tr class="driver-row odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60" data-search="{{ row.search }}">
                  <td class="px-6 py-3 align-middle">
                    <div class="font-semibold text-slate-900">
                      {% if can_modify %}
                      <a class="driver-name-link" href="{{ url_for('drivers.driver_edit', model=row.model, osname=row.osname) }}">{{ row.display_model or row.model }}</a>
                      {% else %}
                      {{ row.display_model or row.model }}
                      {% endif %}
                    </div>
                    <div class="mt-1 text-xs font-medium text-slate-400">{{ row.display_file if row.display_file else 'Driver package' }}</div>
                  </td>
                  <td class="px-6 py-3 align-middle">{{ row.display_osname or row.osname or '-' }}</td>
                  <td class="px-6 py-3 align-middle">{{ row.bundle_id or '-' }}</td>
                  {% if can_modify %}
                  <td class="px-6 py-3 text-right align-middle">
                    <form method="post" action="{{ url_for('drivers.driver_delete') }}" class="m-0" onsubmit="return confirm('Delete driver mapping {{ row.model }} / {{ row.osname }} ?');">
                      <input type="hidden" name="model" value="{{ row.model }}">
                      <input type="hidden" name="osname" value="{{ row.osname }}">
                      <button class="driver-delete-btn" type="submit" title="Supprimer {{ row.display_model or row.model }}" aria-label="Supprimer {{ row.display_model or row.model }}">
                        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6l1-2h6l1 2"></path><path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path><path d="M14 10v6"></path></svg>
                      </button>
                    </form>
                  </td>
                  {% endif %}
                </tr>
              {% endfor %}
              {% if driver_rows|length == 0 %}
                <tr><td colspan="{{ 3 if not can_modify else 4 }}" class="text-center text-muted py-4">No driver mapping</td></tr>
              {% else %}
                <tr id="row-empty" style="display:none;"><td colspan="{{ 3 if not can_modify else 4 }}" class="text-center text-muted py-4">No driver mapping matches your search</td></tr>
              {% endif %}
              </tbody>
            </table>
          </div>
        </section>

      </main>

      <script>
      (function(){
        const input = document.getElementById('drv-search');
        if (!input) return;
        const rows = Array.prototype.slice.call(document.querySelectorAll('#drivers-table tbody tr.driver-row'));
        const emptyRow = document.getElementById('row-empty');

        function applyFilter(){
          const q = (input.value || '').trim().toLowerCase();
          let visibleCount = 0;

          rows.forEach(function(row){
            const hay = (row.getAttribute('data-search') || '');
            const searchOk = (!q || hay.indexOf(q) !== -1);
            if (searchOk){
              row.style.display = '';
              visibleCount++;
            } else {
              row.style.display = 'none';
            }
          });

          if (emptyRow){
            emptyRow.style.display = (visibleCount === 0) ? '' : 'none';
          }
        }

        input.addEventListener('input', applyFilter);

        applyFilter();
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(
            tmpl,
            model_cards=model_cards,
            driver_rows=driver_rows,
            can_modify=can_modify,
            cfg_bundle_id=cfg_bundle_id,
            cfg_bundle_timeout=cfg_bundle_timeout,
            total_models=total_models,
            total_packs=total_packs,
            ready_pack_count=ready_pack_count,
            no_url_count=no_url_count,
            placeholder_count=placeholder_count,
        )

    # =========================
    # CONFIG (global Tanium defaults)
    # =========================
    @bp.route("/drivers/config", methods=["POST"])
    @require_roles('admin', 'operator')
    def drivers_config():
        bundle_id = (request.form.get("default_bundle_id") or "").strip()
        timeout_raw = (request.form.get("default_bundle_timeout") or "").strip()
        try:
            timeout = int(timeout_raw)
            if timeout < 1:
                timeout = 120
        except (TypeError, ValueError):
            timeout = 120
        set_config("default_bundle_id", bundle_id)
        set_config("default_bundle_timeout", str(timeout))
        return redirect(url_for("drivers.drivers_list"))

    # =========================
    # ADD
    # =========================
    @bp.route("/drivers/add", methods=["GET", "POST"])
    @require_roles('admin', 'operator')
    def driver_add():
        if request.method == "POST":
            model    = request.form.get("model_regex", "").strip()
            osname   = request.form.get("os_regex", "").strip()
            url = request.form.get("url", "").strip()
            bundle_id = request.form.get("bundle_id", "").strip()

            if not (model and osname):
                abort(400, "missing model/os regex")
            try:
                re.compile(model)
            except re.error:
                abort(400, "invalid model regex")
            try:
                re.compile(osname)
            except re.error:
                abort(400, "invalid os regex")

            conn = get_db()
            if conn.execute(
                "SELECT 1 FROM drivers WHERE model_regex = ? AND os_regex = ? LIMIT 1;",
                (model, osname),
            ).fetchone() is not None:
                conn.close()
                abort(400, "driver mapping already exists")
            conn.execute(
                "INSERT INTO drivers (model_regex, os_regex, url, bundle_id) VALUES (?, ?, ?, ?);",
                (model, osname, url, bundle_id),
            )
            conn.commit()
            conn.close()
            return redirect(url_for("drivers.drivers_list"))

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Add Driver Mapping</title>
    __HEAD_ASSETS__
      <style>
        :root{
          --bg:#0b1220; --panel:#121a2b; --text:#e6edf3;
          --muted:#8fa1b3; --border:rgba(255,255,255,.06); --heading:#dbe8ff;
        }
        body{background:var(--bg); color:var(--text)}
        .card{background:var(--panel); border:1px solid var(--border)}
        h1{color:var(--heading)!important}
        .form-label{color:var(--heading)!important}
        .form-control,.form-select,textarea{
          background:var(--panel)!important; color:var(--text)!important; border:1px solid var(--border)!important;
        }
        .form-control:focus,.form-select:focus,textarea:focus{
          border-color:#29406b!important; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)!important;
        }
        .form-text{color:var(--muted)}
        .page-breadcrumb-inline{display:none!important}
        .mono{
          font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        }
        .url-actions{display:flex; gap:.5rem; align-items:center; flex-wrap:wrap; margin-top:.5rem}
        .url-actions .btn-browse{margin-right:.5rem}
        .check-result{font-size:.82rem; font-weight:600}
        .check-result.ok{color:#53e39b}
        .check-result.ko{color:#ff7b7b}
        .check-result.pending{color:#ffcc66}
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <h1 class="mb-4">Add Driver Mapping</h1>

        <form method="post" class="card shadow-sm p-3">
          <div class="mb-3">
            <label class="form-label fw-bold">Model Regex</label>
            <input id="model-field" type="text" name="model_regex" class="form-control mono" required autocomplete="off" placeholder="Ex: ^HP\s*EliteBook\s*840\s*G2$">
            <div class="form-text">Regex pattern used to match model name.</div>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">OS Regex</label>
            <input id="os-field" type="text" name="os_regex" class="form-control mono" required placeholder="Ex: ^Windows 10 Enterprise LTSC$">
            <div class="form-text">Regex pattern used to match OS name.</div>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Pack URL</label>
            <input id="url-field" name="url" type="text" class="form-control" autocomplete="off">
            <div class="url-actions">
              <button type="button" class="btn btn-outline-info btn-sm btn-browse" onclick="openFilePicker()">Browse...</button>
              <button type="button" class="btn btn-outline-warning btn-sm" id="check-link-btn">Check Link</button>
              <span class="check-result" id="check-link-result"></span>
              <span class="form-text">Pick a file from /file; its direct URL will be inserted here.</span>
            </div>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Bundle ID</label>
            <input name="bundle_id" type="text" class="form-control mono" autocomplete="off">
          </div>
          <div class="d-flex gap-2">
            <button class="btn btn-success" type="submit">Save</button>
            <a class="btn btn-secondary" href="{{ url_for('drivers.drivers_list') }}">Cancel</a>
          </div>
        </form>

      </div>
      <script>
      function openFilePicker(){
        window.open('{{ url_for("files.list_dir") }}?picker=1',
                    'filePicker',
                    'width=1000,height=700,resizable=yes,scrollbars=yes');
      }
      function setPickedFileUrl(url){
        try{
          const field = document.getElementById('url-field');
          if (field){
            let decoded = url || '';
            try { decoded = decodeURI(decoded); } catch(e) {}
            field.value = decoded;
            field.focus();
          }
        }catch(e){
          console.error(e);
        }
      }
      (function(){
        const modelField = document.getElementById('model-field');
        const osField = document.getElementById('os-field');
        const checkBtn = document.getElementById('check-link-btn');
        const checkResult = document.getElementById('check-link-result');
        const urlField = document.getElementById('url-field');

        if (checkBtn && checkResult && urlField){
          checkBtn.addEventListener('click', async function(){
            const val = (urlField.value || '').trim();
            if (!val){
              checkResult.className = 'check-result ko';
              checkResult.textContent = 'URL is empty.';
              return;
            }
            checkResult.className = 'check-result pending';
            checkResult.textContent = 'Checking...';
            try{
              const resp = await fetch('{{ url_for("apps.app_check_link") }}', {
                method:'POST',
                headers:{'Content-Type':'application/json'},
                body: JSON.stringify({url: val})
              });
              const data = await resp.json();
              checkResult.className = 'check-result ' + (data.ok ? 'ok' : 'ko');
              checkResult.textContent = data.message || (data.ok ? 'Link OK' : 'Link failed');
            } catch(e){
              checkResult.className = 'check-result ko';
              checkResult.textContent = 'Check failed.';
            }
          });
        }
        const form = document.querySelector('form');
        if (form){
          form.addEventListener('submit', function(e){
            for (const field of [modelField, osField]){
              const pattern = (field && field.value || '').trim();
              if (!pattern){
                e.preventDefault();
                return;
              }
            }
          });
        }
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(tmpl)

    # =========================
    # EDIT
    # =========================
    @bp.route("/drivers/edit", methods=["GET", "POST"])
    @require_roles('admin', 'operator')
    def driver_edit():
        conn = get_db()

        if request.method == "POST":
            original_model = request.form.get("original_model", "").strip()
            original_os = request.form.get("original_os", "").strip()
            new_model = request.form.get("model_regex", "").strip()
            try:
                re.compile(new_model)
            except re.error:
                conn.close()
                abort(400, "invalid model regex")

            new_os       = request.form.get("os_regex", "").strip()
            new_url = request.form.get("url", "").strip()
            new_bundle_id = request.form.get("bundle_id", "").strip()

            if not (new_model and new_os):
                conn.close()
                abort(400, "missing model/os regex")
            try:
                re.compile(new_os)
            except re.error:
                conn.close()
                abort(400, "invalid os regex")

            duplicate = conn.execute(
                """
                SELECT 1 FROM drivers
                WHERE model_regex = ? AND os_regex = ?
                  AND NOT (model_regex = ? AND os_regex = ?)
                LIMIT 1;
                """,
                (new_model, new_os, original_model, original_os),
            ).fetchone()
            if duplicate is not None:
                conn.close()
                abort(400, "driver mapping already exists")

            conn.execute(
                """
                UPDATE drivers
                SET model_regex = ?,
                    os_regex = ?,
                    url = ?,
                    bundle_id = ?
                WHERE model_regex = ? AND os_regex = ?;
                """,
                (new_model, new_os, new_url, new_bundle_id, original_model, original_os),
            )
            conn.commit()
            conn.close()
            return redirect(url_for("drivers.drivers_list"))

        model = request.args.get("model", "").strip()
        osname = request.args.get("osname", "").strip()
        row = conn.execute(
            """
            SELECT
              model_regex AS model,
              os_regex AS osname,
              url,
              bundle_id
            FROM drivers
            WHERE model_regex = ? AND os_regex = ?
            LIMIT 1;
            """,
            (model, osname),
        ).fetchone()
        conn.close()
        if row is None:
            abort(404, "driver mapping not found")

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Edit Driver</title>
    __HEAD_ASSETS__
      <style>
        :root{
          --bg:#0b1220; --panel:#121a2b; --text:#e6edf3; --muted:#8fa1b3;
          --border:rgba(255,255,255,.06); --heading:#dbe8ff; --time:#a8c7ff;
        }
        body{background:var(--bg); color:var(--text)}
        .card{background:var(--panel); border:1px solid var(--border)}
        h1{color:var(--heading)!important}

        .form-label{color:var(--heading)!important}
        .form-control,.form-select,textarea{
          background:var(--panel)!important; color:var(--text)!important; border:1px solid var(--border)!important;
        }
        .form-control:focus,.form-select:focus,textarea:focus{
          border-color:#29406b!important; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)!important;
        }
        .page-breadcrumb-inline{display:none!important}
        .mono{
          font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        }
        .regex-status{
          margin-top:.45rem;
          font-size:.88rem;
          font-weight:600;
        }
        .regex-status.ok{color:#44d98a}
        .regex-status.ko{color:#ff7b7b}
        .regex-status.info{color:#9fc4ff}
        .sim-badge{
          display:inline-flex;
          align-items:center;
          padding:.12rem .5rem;
          border-radius:999px;
          font-size:.72rem;
          font-weight:800;
          letter-spacing:.02em;
          border:1px solid var(--border);
          background:rgba(255,255,255,.05);
          color:var(--muted);
          min-height:1.5rem;
        }
        .sim-badge.match{
          background:rgba(68,217,138,.2);
          border-color:rgba(68,217,138,.65);
          color:#7ff0ba;
        }
        .sim-badge.no-match{
          background:rgba(255,123,123,.2);
          border-color:rgba(255,123,123,.6);
          color:#ff9a9a;
        }
        .sim-badge.info{
          background:rgba(159,196,255,.16);
          border-color:rgba(159,196,255,.5);
          color:#b8d3ff;
        }
        .url-actions{display:flex; gap:.5rem; align-items:center; flex-wrap:wrap; margin-top:.5rem}
        .check-result{font-size:.82rem; font-weight:600}
        .check-result.ok{color:#53e39b}
        .check-result.ko{color:#ff7b7b}
        .check-result.pending{color:#ffcc66}

        .meta{font-size:.9rem}
        .meta-label{color:var(--heading); font-weight:600; margin-right:.5rem}
        code.meta-code{color:var(--time)}
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <h1 class="mb-4">Edit Driver Mapping</h1>

        <form id="editDriverForm" method="post" class="card shadow-sm p-3">
          <input type="hidden" name="original_model" value="{{ row.model or '' }}">
          <input type="hidden" name="original_os" value="{{ row.osname or '' }}">
          <div class="mb-3">
            <label class="form-label fw-bold">Model Regex</label>
            <input id="modelRegexInput" type="text" name="model_regex" class="form-control mono" value="{{ row.model or '' }}" placeholder="Ex: HP EliteBook 84[0-9].*">
            <div class="form-text">Regex pattern used to match model name (case-insensitive).</div>

            <div class="mt-2">
              <label class="form-label fw-bold">Simulation Test</label>
              <input id="regexProbeInput" type="text" class="form-control" placeholder="Type a model name to test (ex: HP EliteBook 840 G5)">
              <div class="mt-2">
                <span id="regexSimBadge" class="sim-badge info">WAITING INPUT</span>
              </div>
              <div id="regexStatus" class="regex-status info">Type a test value to validate the regex.</div>
            </div>
          </div>

          <div class="mb-3">
            <label class="form-label fw-bold">OS Regex</label>
            <input id="osRegexInput" type="text" name="os_regex" class="form-control mono" value="{{ row.osname or '' }}" placeholder="Ex: \bWindows\s+10\s+Enterprise\s+LTSC\b" required>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Pack URL</label>
            <input id="url-field" name="url" type="text" class="form-control" value="{{ row.url or '' }}" autocomplete="off">
            <div class="url-actions">
              <button type="button" class="btn btn-outline-info btn-sm btn-browse" onclick="openFilePicker()">Browse...</button>
              <span class="form-text">Pick a file from /file; its direct URL will replace this value.</span>
            </div>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Bundle ID</label>
            <input name="bundle_id" type="text" class="form-control mono" value="{{ row.bundle_id or '' }}" autocomplete="off">
          </div>
          <div class="d-flex gap-2">
            <button class="btn btn-primary" type="submit">Save</button>
            <a class="btn btn-secondary" href="{{ url_for('drivers.drivers_list') }}">Cancel</a>
          </div>
        </form>

      </div>
      <script>
      function openFilePicker(){
        window.open('{{ url_for("files.list_dir") }}?picker=1',
                    'filePicker',
                    'width=1000,height=700,resizable=yes,scrollbars=yes');
      }
      function setPickedFileUrl(url){
        try{
          const field = document.getElementById('url-field');
          if (field){
            let decoded = url || '';
            try { decoded = decodeURI(decoded); } catch(e) {}
            field.value = decoded;
            field.focus();
          }
        }catch(e){
          console.error(e);
        }
      }
      (function(){
        var form = document.getElementById('editDriverForm');
        var modelRegex = document.getElementById('modelRegexInput');
        var osRegex = document.getElementById('osRegexInput');
        var probe = document.getElementById('regexProbeInput');
        var status = document.getElementById('regexStatus');
        var simBadge = document.getElementById('regexSimBadge');
        if (!form) return;

        function setStatus(kind, text){
          if (!status) return;
          status.className = 'regex-status ' + kind;
          status.textContent = text;
        }
        function setSim(kind, text){
          if (!simBadge) return;
          simBadge.className = 'sim-badge ' + kind;
          simBadge.textContent = text;
        }

        function compilePreviewRegex(pattern){
          var flags = 'i';
          var source = pattern;
          if (source.indexOf('(?i)') === 0){
            source = source.substring(4);
          }
          return new RegExp(source, flags);
        }

        function testRegex(){
          var pattern = (modelRegex && modelRegex.value || '').trim();
          var sample = (probe && probe.value || '').trim();
          if (!pattern){
            setStatus('info', 'Enter a regex pattern.');
            setSim('info', 'WAITING INPUT');
            return;
          }
          var rx = null;
          try{
            rx = compilePreviewRegex(pattern);
          }catch(e){
            setStatus('info', 'Preview unavailable in browser; server will validate on save.');
            setSim('no-match', 'NO MATCH');
            return;
          }
          if (!sample){
            setStatus('info', 'Regex OK. Enter a model name to test.');
            setSim('info', 'WAITING INPUT');
            return;
          }
          var ok = rx.test(sample);
          setStatus(ok ? 'ok' : 'ko', ok ? 'Match: ✅' : 'No match: ❌');
          setSim(ok ? 'match' : 'no-match', ok ? 'MATCH' : 'NO MATCH');
        }
        if (modelRegex) modelRegex.addEventListener('input', testRegex);
        if (probe) probe.addEventListener('input', testRegex);
        form.addEventListener('submit', function(e){
          var pattern = (modelRegex && modelRegex.value || '').trim();
          var osPattern = (osRegex && osRegex.value || '').trim();
          if (!pattern){
            e.preventDefault();
            setStatus('ko', 'Regex pattern is required.');
            return;
          }
            if (!osPattern){
              e.preventDefault();
              setStatus('ko', 'OS regex is required.');
              return;
            }
        });

        testRegex();
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(tmpl, row=row)

    # =========================
    # DELETE
    # =========================
    @bp.route("/drivers/delete", methods=["POST"])
    @require_roles('admin', 'operator')
    def driver_delete():
        model = request.form.get("model", "").strip()
        osname = request.form.get("osname", "").strip()
        conn = get_db()
        conn.execute("DELETE FROM drivers WHERE model_regex = ? AND os_regex = ?;", (model, osname))
        conn.commit()
        conn.close()
        return redirect(url_for("drivers.drivers_list"))

    return bp


drivers_bp = _build_drivers_bp()
del _build_drivers_bp


# ========================================================================
# Types blueprint, formerly bp_types.py
# ========================================================================
def _build_types_bp():
    """
    =============================================================================
    bp_types.py - Deployment Type/Profile Management Blueprint
    =============================================================================

    Manages deployment types (profiles) and their associated applications.

    Features:
      - Define deployment types (e.g., BASE, PE, PRE, etc)
      - Map applications to types
      - Control deployment sequence and ordering
      - Prevent reserved type names (BASE, FINALIZE)
    """

    from flask import Blueprint, request, redirect, url_for, abort, session
    from core import get_db, require_roles, render_inline
    from core import as_reboot_flag

    bp = Blueprint("types", __name__)

    RESERVED_GLOBAL = ("BASE", "FINALIZE")  # global stacks
    EMPTY_TYPE_TOKEN = "__EMPTY__"
    EMPTY_LABEL = "EMPTY"


    def _normalize_app_rows(rows):
        """Normalize app rows for template rendering with reboot status."""
        if rows is None:
          raise ValueError("rows must not be None")
        items = []
        for row in rows:
          items.append({
            "name": row["name"],
            "url": row["url"],
            "reboot": as_reboot_flag(row["reboot"]),
            "sort_order": row["sort_order"],
          })
        return items


    def _sort_order_int(value) -> int:
        """Parse sort order value to integer, raise ValueError if invalid."""
        if value is None:
          raise ValueError("sort_order value is required")
        return int(str(value).strip())


    def ensure_postype_catalog(conn):
        """Ensure the readable type/application mapping table exists."""
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS postype_relations (
                postype     TEXT NOT NULL,
                application TEXT NOT NULL DEFAULT ''
            );
            """
        )


    def _render_type_mapping_editor(
        *,
        type_name: str,
        is_new: bool,
        apps_rows,
        selected_app_orders,
    ):
        if apps_rows is None:
          raise ValueError("apps_rows is required")
        apps = []
        for r in apps_rows:
          if r["name"] is None or r["url"] is None:
            raise ValueError("App row missing required fields")
          apps.append(
            {
              "name": r["name"].strip(),
              "url": r["url"].strip(),
            }
          )

        if selected_app_orders is None:
          raise ValueError("selected_app_orders is required")
        selected_app_orders = {str(k): int(v) for k, v in selected_app_orders.items()}

        sequence = []
        for a in apps:
            app_name = a["name"]
            if app_name in selected_app_orders:
                sequence.append(
                    {
                        "kind": "app",
                        "name": a["name"],
                        "order": selected_app_orders.get(app_name, 1000),
                    }
                )
        sequence.sort(key=lambda x: (x["order"], x["name"].lower()))

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>{% if is_new %}Add Type Mapping{% else %}Edit Type Mapping{% endif %}</title>
    __HEAD_ASSETS__
      <style>
        :root{
          --page-bg:#eef3f9;
          --panel:#ffffff;
          --panel-soft:#f8fbff;
          --text:#18324d;
          --muted:#6f7f93;
          --border:#d8e3ef;
          --border-strong:#c7d6e5;
          --shadow:0 10px 28px rgba(15, 23, 42, .08);
          --green:#2bb673;
          --green-soft:#e8f8ef;
          --green-border:#b7e7cb;
          --blue:#3b82f6;
          --blue-soft:#ebf3ff;
          --blue-border:#bfd4ff;
          --danger:#dc3545;
        }
        body{background:var(--page-bg); color:var(--text)}
        h1{color:var(--text)!important}
        .workspace-shell{
          max-width:1680px;
          margin:0 auto;
        }
        .workspace-form{
          background:transparent;
          border:0;
          box-shadow:none;
          padding:0;
        }
        .workspace-header{
          display:flex;
          align-items:center;
          justify-content:space-between;
          gap:1.4rem;
          margin-bottom:1.1rem;
        }
        .workspace-head-main{
          flex:1 1 auto;
          min-width:0;
          display:flex;
          flex-direction:column;
          gap:.4rem;
        }
        .title-row{
          display:flex;
          align-items:center;
          gap:.9rem;
          min-height:46px;
        }
        .workspace-title{
          margin:0;
          font-size:2.05rem;
          line-height:1.05;
          font-weight:780;
          letter-spacing:-.03em;
        }
        .workspace-sub{
          color:var(--muted);
          font-size:.94rem;
        }
        .type-chip-wrap{
          display:flex;
          align-items:center;
          gap:.6rem;
          flex-wrap:wrap;
          margin-left:2px;
        }
        .type-chip-label{
          font-size:.75rem;
          text-transform:uppercase;
          letter-spacing:.12em;
          font-weight:800;
          color:var(--muted);
        }
        .type-input{
          width:min(280px, 100%);
          min-height:40px;
          border-radius:10px;
          border:1px solid var(--border);
          background:#fff;
          color:var(--text);
          box-shadow:0 2px 10px rgba(15,23,42,.04);
          font-weight:650;
        }
        .type-input:focus{
          border-color:#9bbbe3;
          box-shadow:0 0 0 .2rem rgba(59,130,246,.12);
        }
        .workspace-actions{
          display:flex;
          align-items:center;
          gap:.8rem;
          flex:0 0 auto;
          padding-left:.5rem;
        }
        .action-btn{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          min-width:104px;
          height:42px;
          padding:0 1.15rem;
          border-radius:10px;
          border:1px solid transparent;
          text-decoration:none;
          font-weight:700;
          box-shadow:0 2px 10px rgba(15,23,42,.06);
        }
        .action-btn-save{
          background:var(--green);
          color:#fff;
        }
        .action-btn-save:hover{
          color:#fff;
          background:#239a60;
        }
        .action-btn-cancel{
          background:#fff;
          color:#5d6e82;
          border-color:var(--border);
        }
        .action-btn-cancel:hover{
          color:#425569;
          background:#f8fbfe;
          border-color:var(--border-strong);
        }
        .helper{
          color:var(--muted);
          font-size:.82rem;
          font-weight:600;
          margin:0;
        }
        .map-grid{
          display:grid;
          grid-template-columns:minmax(0, 1fr) minmax(0, 1.25fr);
          gap:1rem;
          align-items:start;
        }
        .workspace-card{
          background:var(--panel);
          border:1px solid var(--border);
          border-radius:18px;
          box-shadow:var(--shadow);
          padding:1rem;
          min-height:560px;
        }
        .source-pane, .seq-pane{
          position:relative;
          overflow:hidden;
        }
        .pane-head{
          display:flex;
          justify-content:space-between;
          align-items:center;
          gap:.75rem;
          margin-bottom:.85rem;
          flex-wrap:wrap;
        }
        .pane-title{
          margin:0;
          display:flex;
          align-items:center;
          gap:.55rem;
          color:var(--text);
          font-size:1rem;
          font-weight:780;
          letter-spacing:-.01em;
        }
        .soft-badge{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          min-width:28px;
          height:28px;
          padding:0 .5rem;
          border-radius:999px;
          border:1px solid transparent;
          font-size:.73rem;
          font-weight:800;
          letter-spacing:.02em;
          line-height:1;
        }
        .soft-badge.app{
          color:#0e7a47;
          background:var(--green-soft);
          border-color:var(--green-border);
        }
        .soft-badge.cfg{
          color:#2355b9;
          background:var(--blue-soft);
          border-color:var(--blue-border);
        }
        .filter-input{
          min-width:180px;
          height:38px;
          border-radius:10px;
          border:1px solid var(--border);
          background:#fff;
          color:var(--text);
          box-shadow:none;
        }
        .filter-input:focus{
          border-color:#9bbbe3;
          box-shadow:0 0 0 .2rem rgba(59,130,246,.12);
        }
        .filter-input::placeholder{color:var(--muted); opacity:1}
        .source-list, .seq-list{
          margin:0;
          padding:0;
          list-style:none;
          display:flex;
          flex-direction:column;
          gap:.55rem;
          max-height:470px;
          overflow:auto;
        }
        .source-item{
          border:1px solid var(--border);
          border-radius:14px;
          background:var(--panel-soft);
          padding:.65rem .75rem;
          cursor:grab;
          user-select:none;
          transition:border-color .15s ease, box-shadow .15s ease, transform .15s ease, background .15s ease;
        }
        .source-item:hover{
          border-color:var(--border-strong);
          box-shadow:0 8px 18px rgba(15,23,42,.06);
          transform:translateY(-1px);
        }
        .source-item:active{cursor:grabbing}
        .source-item.is-used{display:none !important}
        .source-item.dragging{
          opacity:.58;
          transform:scale(.99);
        }
        .source-row{
          display:flex;
          align-items:center;
          gap:.65rem;
          min-width:0;
        }
        .kind-icon{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          width:32px;
          height:32px;
          border-radius:999px;
          flex:0 0 auto;
          font-size:.9rem;
        }
        .source-pane-app .kind-icon{
          background:var(--green-soft);
          color:#0d7a46;
          border:1px solid var(--green-border);
        }
        .source-pane-cfg .kind-icon{
          background:var(--blue-soft);
          color:#2759bd;
          border:1px solid var(--blue-border);
        }
        .source-name{
          min-width:0;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
          font-weight:700;
          color:var(--text);
        }
        .btn-add-inline{
          margin-left:auto;
          width:30px;
          height:30px;
          border-radius:10px;
          border:1px solid transparent;
          background:transparent;
          color:#7f90a4;
          line-height:1;
          padding:0;
          font-size:1rem;
          font-weight:800;
          opacity:.18;
          transition:opacity .15s ease, background .15s ease, color .15s ease, border-color .15s ease;
        }
        .source-item:hover .btn-add-inline,
        .source-item:focus-within .btn-add-inline{
          opacity:1;
        }
        .source-pane-app .btn-add-inline:hover{
          background:var(--green);
          color:#fff;
          border-color:#239a60;
        }
        .source-pane-cfg .btn-add-inline:hover{
          background:var(--blue);
          color:#fff;
          border-color:#2d6fda;
        }
        .seq-pane{
          background:linear-gradient(180deg, #ffffff, #fbfdff);
        }
        .seq-head-meta{
          color:var(--muted);
          font-size:.88rem;
          font-weight:650;
        }
        .seq-list{
          position:relative;
          padding-left:0;
        }
        .seq-item{
          position:relative;
          padding-left:0;
          cursor:grab;
        }
        .seq-item:active{cursor:grabbing}
        .seq-item.dragging{opacity:.5}
        .seq-row{
          position:relative;
          display:grid;
          grid-template-columns:42px minmax(0, 1fr) auto;
          gap:.8rem;
          align-items:start;
          padding:.1rem 0;
        }
        .seq-row::before{
          content:'';
          position:absolute;
          left:20px;
          top:34px;
          bottom:-18px;
          width:2px;
          background:linear-gradient(180deg, rgba(203,213,225,.95), rgba(226,232,240,.55));
          border-radius:999px;
        }
        .seq-item:last-child .seq-row::before{display:none}
        .seq-order{
          width:40px;
          height:40px;
          border-radius:999px;
          border:1px solid var(--border-strong);
          background:#fff;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          font-size:.82rem;
          font-weight:800;
          color:#43566c;
          box-shadow:0 4px 14px rgba(15,23,42,.06);
          z-index:1;
        }
        .seq-card{
          display:flex;
          align-items:center;
          gap:.65rem;
          min-width:0;
          padding:.68rem .8rem;
          border-radius:14px;
          border:1px solid var(--border);
          background:var(--panel-soft);
          transition:border-color .15s ease, box-shadow .15s ease;
        }
        .seq-item:hover .seq-card{
          border-color:var(--border-strong);
          box-shadow:0 8px 20px rgba(15,23,42,.06);
        }
        .kind-badge{
          border-radius:999px;
          padding:.18rem .55rem;
          font-size:.7rem;
          font-weight:800;
          border:1px solid transparent;
          flex:0 0 auto;
        }
        .kind-badge.app{
          color:#0e7a47;
          background:var(--green-soft);
          border-color:var(--green-border);
        }
        .kind-badge.cfg{
          color:#2355b9;
          background:var(--blue-soft);
          border-color:var(--blue-border);
        }
        .seq-name{
          min-width:0;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
          font-weight:700;
          color:var(--text);
        }
        .seq-remove{
          width:30px;
          height:30px;
          border-radius:10px;
          border:1px solid #f0c7cb;
          background:#fff7f8;
          color:var(--danger);
          line-height:1;
          padding:0;
          font-weight:800;
          opacity:0;
          transition:opacity .15s ease, background .15s ease, border-color .15s ease;
          align-self:center;
        }
        .seq-item:hover .seq-remove,
        .seq-item:focus-within .seq-remove{
          opacity:1;
        }
        .seq-remove:hover{
          background:#ffecee;
          border-color:#e4a2a9;
          color:#c12739;
        }
        .seq-list.is-drop-ready{
          border:1px dashed #9bbbe3;
          border-radius:16px;
          padding:.55rem;
          background:#f8fbff;
        }
        .seq-item.drop-before .seq-card{
          box-shadow:0 -3px 0 0 #8bb6f3 inset;
          border-top-color:#8bb6f3;
        }
        .seq-drop-indicator{
          border:1px dashed #9bbbe3;
          border-radius:14px;
          background:#f3f8ff;
          color:#6280a0;
          text-align:center;
          padding:.8rem .75rem;
          font-size:.9rem;
          font-weight:700;
        }
        .empty-tip{
          color:var(--muted);
          font-size:.92rem;
          text-align:center;
          padding:.75rem .35rem .2rem;
        }
        @media (max-width: 1200px){
          .map-grid{grid-template-columns:1fr}
          .workspace-card{min-height:auto}
          .source-list, .seq-list{max-height:none}
        }
        @media (max-width: 900px){
          .workspace-header{
            flex-direction:column;
            align-items:stretch;
          }
          .workspace-actions{
            justify-content:flex-end;
            padding-left:0;
          }
          .title-row{min-height:auto; flex-wrap:wrap;}
        }
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid workspace-shell">
        <form id="mappingForm" method="post" class="workspace-form">
          <div class="workspace-header">
            <div class="workspace-head-main">
              <div class="title-row">
                <h1 class="workspace-title">{% if is_new %}Edit Mapping : New Type{% else %}Edit Mapping : [{{ type_name }}]{% endif %}</h1>
              </div>
              {% if is_new %}
              <div class="type-chip-wrap">
                <span class="type-chip-label">Type</span>
                <input type="text" name="type_name" class="form-control type-input" placeholder="BASE, DIVAPOS, ERPLY..." required>
              </div>
              {% endif %}
            </div>
            <div class="workspace-actions">
              <button class="action-btn action-btn-save" type="submit">Save</button>
              <a class="action-btn action-btn-cancel" href="{{ url_for('types.type_list') }}">Cancel</a>
            </div>
          </div>

          <div id="hiddenFields">
            {% for app in apps %}
            <input id="use_app_{{ app.name }}" type="checkbox" name="use_app_{{ app.name }}" value="1" hidden {% if app.name in selected_app_orders %}checked{% endif %}>
            <input id="order_app_{{ app.name }}" type="hidden" name="order_{{ app.name }}" value="{{ selected_app_orders.get(app.name, 1000) }}">
            {% endfor %}
          </div>

          <div class="map-grid">
            <section class="workspace-card source-pane source-pane-app">
              <div class="pane-head">
                <p class="pane-title"><span class="soft-badge app">Apps</span> Available Apps</p>
                <input type="text" id="appsFilter" class="form-control form-control-sm filter-input" placeholder="Filter apps...">
              </div>
              <ul id="appsSource" class="source-list">
                {% for app in apps %}
                <li class="source-item" data-kind="app" data-id="{{ app.name }}" data-name="{{ app.name }}" data-search="{{ app.name|lower }}" draggable="true">
                  <div class="source-row">
                    <span class="kind-icon" aria-hidden="true">📦</span>
                    <span class="source-name">{{ app.name }}</span>
                    <button class="btn-add-inline" type="button" title="Add">+</button>
                  </div>
                </li>
                {% endfor %}
              </ul>
              {% if apps|length == 0 %}<div class="empty-tip">No apps in catalog</div>{% endif %}
            </section>

            <section class="workspace-card seq-pane">
              <div class="pane-head">
                <p class="pane-title">Deployment Sequence</p>
                <div class="seq-head-meta"><span id="seqCount">{{ sequence|length }}</span> item(s)</div>
              </div>
              <ul id="seqList" class="seq-list">
                {% for it in sequence %}
                <li class="seq-item" data-kind="{{ it.kind }}" data-id="{{ it.name }}" data-name="{{ it.name }}" draggable="true">
                  <div class="seq-row">
                    <span class="seq-order">{{ loop.index }}</span>
                    <div class="seq-card">
                      <span class="kind-badge app">App</span>
                      <span class="seq-name">{{ it.name }}</span>
                    </div>
                    <button class="seq-remove" type="button" title="Remove">✕</button>
                  </div>
                </li>
                {% endfor %}
              </ul>
              <div id="seqDropHint" class="seq-drop-indicator" style="display:none">Drop here to insert in the sequence</div>
              <div id="seqEmpty" class="empty-tip" {% if sequence|length > 0 %}style="display:none"{% endif %}>No deployment item selected</div>
            </section>
          </div>
        </form>
      </div>

      <script>
      (function(){
        var form = document.getElementById('mappingForm');
        var appsSource = document.getElementById('appsSource');
        var seqList = document.getElementById('seqList');
        var seqCount = document.getElementById('seqCount');
        var seqEmpty = document.getElementById('seqEmpty');
        var seqDropHint = document.getElementById('seqDropHint');
        var appsFilter = document.getElementById('appsFilter');
        if (!form || !appsSource || !seqList) return;

        var dragItem = null;
        var dragSourceType = '';

        function sourceItems(){
          return Array.prototype.slice.call(document.querySelectorAll('.source-item'));
        }
        function seqItems(){
          return Array.prototype.slice.call(seqList.querySelectorAll('.seq-item'));
        }
        function keyOf(kind, id){
          return String(kind) + ':' + String(id);
        }
        function usedSet(){
          var used = new Set();
          seqItems().forEach(function(it){
            used.add(keyOf(it.getAttribute('data-kind'), it.getAttribute('data-id')));
          });
          return used;
        }
        function clearDropMarkers(){
          seqList.classList.remove('is-drop-ready');
          seqItems().forEach(function(it){
            it.classList.remove('drop-before');
          });
          if (seqDropHint) seqDropHint.style.display = 'none';
        }
        function showDropHint(show){
          if (!seqDropHint) return;
          seqDropHint.style.display = show ? '' : 'none';
        }

        function markSourcesFromSequence(){
          var used = usedSet();
          sourceItems().forEach(function(item){
            var k = keyOf(item.getAttribute('data-kind'), item.getAttribute('data-id'));
            if (used.has(k)){
              item.classList.add('is-used');
            } else {
              item.classList.remove('is-used');
            }
          });
        }

        function buildSeqItem(kind, id, name){
          var li = document.createElement('li');
          li.className = 'seq-item';
          li.setAttribute('data-kind', kind);
          li.setAttribute('data-id', String(id));
          li.setAttribute('data-name', name || '');
          li.setAttribute('draggable', 'true');
          li.innerHTML =
            '<div class="seq-row">' +
              '<span class="seq-order">1</span>' +
              '<div class="seq-card">' +
                '<span class="kind-badge app">App</span>' +
                '<span class="seq-name"></span>' +
              '</div>' +
              '<button class="seq-remove" type="button" title="Remove">✖</button>' +
            '</div>';
          li.querySelector('.seq-name').textContent = name || '';
          return li;
        }

        function addToSequence(kind, id, name, beforeNode){
          var exists = seqList.querySelector('.seq-item[data-kind="' + kind + '"][data-id="' + id + '"]');
          if (exists) return;
          var newItem = buildSeqItem(kind, id, name);
          if (beforeNode && beforeNode.parentNode === seqList){
            seqList.insertBefore(newItem, beforeNode);
          } else {
            seqList.appendChild(newItem);
          }
          refreshUi();
        }

        function removeFromSequence(item){
          if (!item) return;
          if (item.parentNode === seqList){
            seqList.removeChild(item);
          }
          refreshUi();
        }

        function refreshUi(){
          seqItems().forEach(function(it, idx){
            var ord = it.querySelector('.seq-order');
            if (ord) ord.textContent = String(idx + 1);
          });
          var n = seqItems().length;
          if (seqCount) seqCount.textContent = String(n);
          if (seqEmpty) seqEmpty.style.display = n ? 'none' : '';
          markSourcesFromSequence();
          syncHiddenFields();
          applySourceFilter(appsSource, appsFilter);
          clearDropMarkers();
        }

        function syncHiddenFields(){
          sourceItems().forEach(function(s){
            var kind = s.getAttribute('data-kind');
            var id = s.getAttribute('data-id');
            var useA = document.getElementById('use_app_' + id);
            var ordA = document.getElementById('order_app_' + id);
            if (useA) useA.checked = false;
            if (ordA) ordA.value = '1000';
          });

          seqItems().forEach(function(it, idx){
            var kind = it.getAttribute('data-kind');
            var id = it.getAttribute('data-id');
            var orderVal = String((idx + 1) * 10);
            var useA = document.getElementById('use_app_' + id);
            var ordA = document.getElementById('order_app_' + id);
            if (useA) useA.checked = true;
            if (ordA) ordA.value = orderVal;
          });
        }

        function bindSourceEvents(root){
          root.addEventListener('click', function(e){
            var addBtn = e.target.closest('.btn-add-inline');
            if (!addBtn) return;
            var item = e.target.closest('.source-item');
            if (!item) return;
            addToSequence(item.getAttribute('data-kind'), item.getAttribute('data-id'), item.getAttribute('data-name'));
          });

          root.addEventListener('dblclick', function(e){
            var item = e.target.closest('.source-item');
            if (!item) return;
            addToSequence(item.getAttribute('data-kind'), item.getAttribute('data-id'), item.getAttribute('data-name'));
          });

          root.addEventListener('dragstart', function(e){
            var item = e.target.closest('.source-item');
            if (!item || item.classList.contains('is-used')) return;
            dragItem = item;
            dragSourceType = 'source';
            item.classList.add('dragging');
            seqList.classList.add('is-drop-ready');
            showDropHint(seqItems().length === 0);
            if (e.dataTransfer){
              e.dataTransfer.effectAllowed = 'copyMove';
              try { e.dataTransfer.setData('text/plain', item.getAttribute('data-kind') + ':' + item.getAttribute('data-id')); } catch (err) {}
            }
          });

          root.addEventListener('dragend', function(e){
            var item = e.target.closest('.source-item');
            if (item) item.classList.remove('dragging');
            dragItem = null;
            dragSourceType = '';
            clearDropMarkers();
          });
        }

        function getDropTarget(clientY){
          var items = seqItems().filter(function(item){ return item !== dragItem; });
          var target = null;
          items.forEach(function(item){
            item.classList.remove('drop-before');
          });
          for (var i = 0; i < items.length; i++){
            var item = items[i];
            var rect = item.getBoundingClientRect();
            if (clientY < rect.top + (rect.height / 2)){
              target = item;
              break;
            }
          }
          if (target){
            target.classList.add('drop-before');
          }
          return target;
        }

        function bindSeqEvents(){
          seqList.addEventListener('click', function(e){
            var btn = e.target.closest('.seq-remove');
            if (!btn) return;
            var row = btn.closest('.seq-item');
            removeFromSequence(row);
          });

          seqList.addEventListener('dragstart', function(e){
            var item = e.target.closest('.seq-item');
            if (!item) return;
            dragItem = item;
            dragSourceType = 'sequence';
            item.classList.add('dragging');
            seqList.classList.add('is-drop-ready');
            if (e.dataTransfer){
              e.dataTransfer.effectAllowed = 'move';
              try { e.dataTransfer.setData('text/plain', item.getAttribute('data-kind') + ':' + item.getAttribute('data-id')); } catch (err) {}
            }
          });

          seqList.addEventListener('dragover', function(e){
            if (!dragItem) return;
            e.preventDefault();
            seqList.classList.add('is-drop-ready');
            var target = getDropTarget(e.clientY);
            showDropHint(!target && seqItems().length === 0);
            if (dragSourceType === 'sequence' && dragItem.parentNode === seqList){
              seqList.insertBefore(dragItem, target || null);
            }
          });

          seqList.addEventListener('drop', function(e){
            if (!dragItem) return;
            e.preventDefault();
            var target = getDropTarget(e.clientY);
            if (dragSourceType === 'source'){
              addToSequence(
                dragItem.getAttribute('data-kind'),
                dragItem.getAttribute('data-id'),
                dragItem.getAttribute('data-name'),
                target
              );
            } else {
              refreshUi();
            }
            if (dragItem) dragItem.classList.remove('dragging');
            dragItem = null;
            dragSourceType = '';
            clearDropMarkers();
          });

          seqList.addEventListener('dragleave', function(e){
            if (!seqList.contains(e.relatedTarget)){
              clearDropMarkers();
              if (dragItem){
                seqList.classList.add('is-drop-ready');
                showDropHint(seqItems().length === 0);
              }
            }
          });

          seqList.addEventListener('dragend', function(){
            if (dragItem) dragItem.classList.remove('dragging');
            dragItem = null;
            dragSourceType = '';
            clearDropMarkers();
            refreshUi();
          });
        }

        function applySourceFilter(list, input){
          var q = ((input && input.value) || '').toLowerCase().trim();
          Array.prototype.slice.call(list.querySelectorAll('.source-item')).forEach(function(item){
            if (item.classList.contains('is-used')){
              item.style.display = 'none';
              return;
            }
            var hay = (item.getAttribute('data-search') || '').toLowerCase();
            item.style.display = (!q || hay.indexOf(q) !== -1) ? '' : 'none';
          });
        }

        if (appsFilter){
          appsFilter.addEventListener('input', function(){ applySourceFilter(appsSource, appsFilter); });
        }
        bindSourceEvents(appsSource);
        bindSeqEvents();

        form.addEventListener('submit', function(){
          syncHiddenFields();
        });

        refreshUi();
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(
            tmpl,
            is_new=is_new,
            type_name=type_name,
            apps=apps,
            sequence=sequence,
            selected_app_orders=selected_app_orders,
        )


    # ---------------------------------------------------------------------------
    # List
    # ---------------------------------------------------------------------------
    @bp.route("/type")
    def type_list():
        conn = get_db()
        ensure_postype_catalog(conn)

        # Types declares dans le fichier, y compris ceux sans application.
        types_from_map = conn.execute(
            """
            SELECT DISTINCT UPPER(TRIM(IFNULL(postype, ''))) AS postype
            FROM postype_relations
            WHERE TRIM(IFNULL(postype, '')) <> ''
            ORDER BY postype ASC;
            """
        ).fetchall()

        # Types vus sur les machines
        types_from_pc = conn.execute(
            "SELECT DISTINCT UPPER(TRIM(IFNULL(postype, ''))) AS postype FROM newcomputer WHERE TRIM(IFNULL(postype, '')) <> '' ORDER BY postype ASC;"
        ).fetchall()

        ts = set()
        for r in types_from_map:
            if r["postype"] is not None:
                ts.add(r["postype"])
        for r in types_from_pc:
            if r["postype"] is not None:
                ts.add(r["postype"])

        # Nombre de machines par type (for summary)
        counts_rows = conn.execute(
            "SELECT UPPER(TRIM(IFNULL(postype, ''))) AS postype, COUNT(*) AS cnt FROM newcomputer WHERE TRIM(IFNULL(postype, '')) <> '' GROUP BY UPPER(TRIM(IFNULL(postype, '')));"
        ).fetchall()
        count_by_type = {r["postype"]: r["cnt"] for r in counts_rows}

        # Détails pour les types normaux (hors BASE / FINALIZE)
        normal_types = []
        for t in sorted(ts, key=lambda x: (x or "").lower()):
            if (t or "").upper() in RESERVED_GLOBAL or (t or "") == "":
                continue
            rows_apps = conn.execute(
                """
                SELECT a.name, a.url, a.reboot, (pr.rowid + 1) * 10 AS sort_order
                FROM postype_relations pr
                JOIN apps a ON a.name = pr.application
                WHERE UPPER(TRIM(IFNULL(pr.postype, ''))) = ? AND TRIM(IFNULL(pr.application, '')) <> ''
                ORDER BY pr.rowid;
                """,
                (t,),
            ).fetchall()
            apps_norm = _normalize_app_rows(rows_apps)

            sequence = []
            for app in apps_norm:
                sequence.append({
                    "kind": "app",
                    "name": app["name"],
                    "url": app["url"],
                    "reboot": app["reboot"],
                    "sort_order": app["sort_order"],
                    "sort_num": _sort_order_int(app["sort_order"]),
                })

            sequence.sort(key=lambda x: (x["sort_num"], (x["name"] or "").lower()))

            normal_types.append({
                "type": t,
                "apps": apps_norm,
                "sequence": sequence,
                "app_count": len(rows_apps),
                "machine_count": count_by_type.get(t, 0),
            })

        # Global stacks (toujours affichées)
        def load_stage(stage_name: str):
            rows_apps = conn.execute(
                """
                SELECT a.name, a.url, a.reboot, (pr.rowid + 1) * 10 AS sort_order
                FROM postype_relations pr
                JOIN apps a ON a.name = pr.application
                WHERE UPPER(pr.postype) = ? AND TRIM(IFNULL(pr.application, '')) <> ''
                ORDER BY pr.rowid;
                """,
                (stage_name.upper(),),
            ).fetchall()
            apps_norm = _normalize_app_rows(rows_apps)

            sequence = []
            for app in apps_norm:
                sequence.append({
                    "kind": "app",
                    "name": app["name"],
                    "url": app["url"],
                    "reboot": app["reboot"],
                    "sort_order": app["sort_order"],
                    "sort_num": _sort_order_int(app["sort_order"]),
                })

            sequence.sort(key=lambda x: (x["sort_num"], (x["name"] or "").lower()))

            return {
                "type": stage_name.upper(),
                "apps": apps_norm,
                "sequence": sequence,
            }

        special_base = load_stage("BASE")
        special_finalize = load_stage("FINALIZE")

        conn.close()

        role = (session.get("role") or "").lower()
        can_modify = role in ("admin", "operator")

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Type Mapping</title>
    __HEAD_ASSETS__
      <style>
        :root{
          --page-bg:#eef3f9;
          --panel:#ffffff;
          --panel-muted:#f7fafc;
          --text:#17324d;
          --muted:#6b7a90;
          --border:#d8e2ee;
          --border-strong:#c6d4e4;
          --link:#2056d8;
          --accent:#2bb673;
          --danger:#dc3545;
          --shadow:0 10px 26px rgba(15, 23, 42, .08);
          --base-bg:#e7faf6;
          --base-border:#14b8a6;
          --profile-bg:#ebf2ff;
          --profile-border:#3b82f6;
          --final-bg:#f5edff;
          --final-border:#a855f7;
        }
        body{background:var(--page-bg); color:var(--text)}
        a,a:hover{color:var(--link)}
        h1{color:var(--text)!important}
        .text-muted{color:var(--muted)!important}
        .page-shell{max-width:1600px; margin:0 auto}
        .page-header{
          display:flex;
          align-items:center;
          justify-content:space-between;
          gap:1rem;
          margin-bottom:1rem;
        }
        .page-title{
          margin:0;
          font-size:2.4rem;
          line-height:1.05;
          font-weight:750;
          letter-spacing:-.03em;
        }
        .toolbar{display:flex; align-items:center; justify-content:flex-end}
        .chip{
          display:inline-flex;
          align-items:center;
          gap:.7rem;
          text-decoration:none;
          padding:.35rem .95rem .35rem .4rem;
          background:#fff;
          border:1px solid var(--border);
          border-radius:12px;
          color:var(--text);
          box-shadow:0 2px 8px rgba(15,23,42,.06);
          font-weight:650;
          transition:background .15s ease, border-color .15s ease, box-shadow .15s ease;
        }
        .chip:hover{
          color:var(--text);
          border-color:#bfd0e3;
          box-shadow:0 6px 18px rgba(15,23,42,.1);
        }
        .modicon{
          width:36px;
          height:36px;
          border-radius:10px;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          background:#2bb673;
          box-shadow:inset 0 1px 0 rgba(255,255,255,.25);
        }
        .modicon svg{width:18px;height:18px}
        .modicon svg *{
          stroke:#fff;
          stroke-width:2.1;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .mapping-flow{
          display:flex;
          flex-direction:column;
          gap:.85rem;
        }
        .mapping-block{
          position:relative;
          background:var(--panel);
          border:1px solid var(--border);
          border-left-width:6px;
          border-radius:18px;
          box-shadow:var(--shadow);
          overflow:hidden;
        }
        .mapping-block.block-base{border-left-color:var(--base-border); background:linear-gradient(180deg, var(--base-bg), #ffffff 130px)}
        .mapping-block.block-profile{border-left-color:var(--profile-border); background:linear-gradient(180deg, var(--profile-bg), #ffffff 150px)}
        .mapping-block.block-final{border-left-color:var(--final-border); background:linear-gradient(180deg, var(--final-bg), #ffffff 130px)}
        .accordion-entry + .accordion-entry{border-top:1px solid rgba(198,212,228,.6)}
        .accordion-head{
          display:flex;
          align-items:stretch;
          gap:.85rem;
          padding:1rem 1.15rem;
        }
        .accordion-trigger{
          flex:1 1 auto;
          min-width:0;
          border:0;
          background:transparent;
          padding:0;
          display:flex;
          align-items:center;
          gap:1rem;
          text-align:left;
          color:inherit;
        }
        .accordion-copy{
          min-width:0;
          display:flex;
          flex-direction:column;
          gap:.18rem;
        }
        .accordion-kicker{
          font-size:.71rem;
          font-weight:800;
          letter-spacing:.12em;
          text-transform:uppercase;
          color:var(--muted);
        }
        .accordion-title-row{
          display:flex;
          align-items:center;
          gap:.7rem;
          flex-wrap:wrap;
        }
        .accordion-title{
          font-size:1.12rem;
          font-weight:800;
          letter-spacing:-.01em;
          color:var(--text);
        }
        .accordion-summary-text{
          color:var(--muted);
          font-size:.94rem;
          white-space:normal;
        }
        .accordion-subtitle{
          color:var(--muted);
          font-size:.84rem;
        }
        .accordion-chevron{
          flex:0 0 auto;
          width:38px;
          height:38px;
          border-radius:10px;
          border:1px solid var(--border);
          background:#fff;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          color:#46627f;
          transition:transform .18s ease, background .18s ease, border-color .18s ease;
        }
        .accordion-chevron svg{
          width:18px;
          height:18px;
          stroke:currentColor;
          stroke-width:2.2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .accordion-entry.is-open > .accordion-head .accordion-chevron{
          transform:rotate(180deg);
          background:#f8fbff;
          border-color:#bfd0e3;
        }
        .summary-actions{
          flex:0 0 auto;
          display:flex;
          align-items:center;
          gap:.55rem;
        }
        .icon-btn{
          width:38px;
          height:38px;
          border-radius:10px;
          border:1px solid var(--border);
          background:#fff;
          color:#21405f;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          text-decoration:none;
          transition:background .15s ease, border-color .15s ease, color .15s ease;
        }
        .icon-btn svg{
          width:17px;
          height:17px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .icon-btn:hover{
          background:#f7fafc;
          border-color:#bfd0e3;
          color:#17324d;
        }
        .icon-btn-danger{
          color:var(--danger);
          border-color:#f1c5cb;
          background:#fff7f8;
        }
        .icon-btn-danger:hover{
          background:#ffecee;
          border-color:#e59da6;
          color:#c22738;
        }
        .accordion-panel{
          display:none;
          padding:0 1.15rem 1.15rem;
        }
        .accordion-entry.is-open > .accordion-panel{display:block}
        .mapping-list{
          display:flex;
          flex-direction:column;
          gap:.75rem;
        }
        .mapping-item{
          display:flex;
          align-items:flex-start;
          justify-content:space-between;
          gap:1rem;
          padding:.9rem 1rem;
          border:1px solid var(--border);
          border-radius:14px;
          background:rgba(255,255,255,.82);
        }
        .mapping-item-main{
          min-width:0;
          display:flex;
          align-items:flex-start;
          gap:.8rem;
          flex:1 1 auto;
        }
        .mapping-item-icon{
          width:38px;
          height:38px;
          border-radius:12px;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          background:#f3f7fb;
          border:1px solid var(--border);
          font-size:1rem;
          line-height:1;
          flex:0 0 auto;
        }
        .mapping-item-copy{
          min-width:0;
          display:flex;
          flex-direction:column;
          gap:.3rem;
        }
        .mapping-item-title{
          font-weight:760;
          color:var(--text);
          line-height:1.2;
          word-break:break-word;
        }
        .mapping-item-meta{
          display:flex;
          align-items:center;
          gap:.45rem;
          flex-wrap:wrap;
          color:var(--muted);
          font-size:.84rem;
        }
        .soft-pill{
          display:inline-flex;
          align-items:center;
          padding:.18rem .5rem;
          border-radius:999px;
          font-size:.72rem;
          font-weight:750;
          border:1px solid #d8e2ee;
          background:#f6f9fc;
          color:#36506c;
        }
        .soft-pill.warn{
          background:#fff4db;
          border-color:#f7d690;
          color:#9a6500;
        }
        .mapping-link{
          font-size:.8rem;
          color:#355574;
          word-break:break-all;
          overflow-wrap:anywhere;
          font-family:"Consolas","SFMono-Regular","Roboto Mono",monospace;
        }
        .mapping-open{
          flex:0 0 auto;
          align-self:center;
          border:1px solid var(--border);
          background:#fff;
          color:#21405f;
          border-radius:10px;
          padding:.5rem .75rem;
          text-decoration:none;
          font-weight:650;
          font-size:.85rem;
          word-break:break-all;
          transition:background .15s ease, border-color .15s ease;
        }
        .mapping-open:hover{
          background:#f7fafc;
          border-color:#bfd0e3;
          color:#17324d;
        }
        .empty-note{
          color:var(--muted);
          font-size:.9rem;
          font-style:italic;
          padding:.2rem 0;
        }
        .flow-separator{
          display:flex;
          align-items:center;
          justify-content:center;
          padding:.1rem 0;
        }
        .flow-track{
          display:flex;
          flex-direction:column;
          align-items:center;
          gap:.2rem;
        }
        .flow-line{
          width:2px;
          height:26px;
          background:linear-gradient(180deg, rgba(148,163,184,.15), rgba(148,163,184,.75), rgba(148,163,184,.15));
          border-radius:999px;
        }
        .flow-arrow{
          width:34px;
          height:34px;
          border-radius:999px;
          border:1px solid #c8d6e6;
          background:#fff;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          color:#5b728d;
          box-shadow:0 6px 18px rgba(15,23,42,.08);
          font-size:1rem;
          line-height:1;
        }
        .profiles-shell{
          display:flex;
          flex-direction:column;
          gap:0;
          border-top:1px solid rgba(198,212,228,.55);
        }
        .modal-backdrop{
          position:fixed; inset:0; background:rgba(15,23,42,.45); display:none; z-index:1050;
        }
        .modal-card{
          position:fixed; inset:0; display:none; align-items:center; justify-content:center; z-index:1060;
          padding:1rem;
        }
        .modal-box{
          width:100%;
          max-width:520px;
          background:#fff;
          border:1px solid var(--border);
          border-radius:16px;
          box-shadow:0 24px 60px rgba(15,23,42,.22);
          padding:1.25rem;
        }
        .modal-title{color:var(--text); font-weight:800; margin-bottom:.35rem}
        .modal-text{color:var(--text)}
        .modal-muted{color:var(--muted)}
        @media (max-width: 900px){
          .page-header{
            align-items:flex-start;
            flex-direction:column;
          }
          .toolbar{width:100%; justify-content:flex-start}
          .accordion-head{
            flex-direction:column;
            align-items:stretch;
          }
          .summary-actions{
            width:100%;
            justify-content:flex-end;
          }
          .mapping-item{
            flex-direction:column;
          }
          .mapping-open{
            align-self:flex-start;
          }
        }
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid page-shell">

        <div class="page-header">
          <h1 class="page-title">Type Mapping</h1>
          <div class="toolbar">
            {% if can_modify %}
            <a class="chip btn-primary-green" href="{{ url_for('types.type_add') }}">
              <span class="modicon mi-add">
                <svg viewBox="0 0 24 24"><path d="M12 5v14"/><path d="M5 12h14"/></svg>
              </span><span class="label">Add</span>
            </a>
            {% endif %}
          </div>
        </div>

        <div class="mapping-flow">
          {% if normal_types|length > 0 %}
          {% for item in normal_types %}
          <section class="mapping-block block-profile">
            <div class="accordion-entry" data-accordion>
              <div class="accordion-head">
                <button class="accordion-trigger" type="button" data-accordion-trigger aria-expanded="false">
                  <div class="accordion-copy">
                    <div class="accordion-title-row">
                      <span class="accordion-title">{{ item.type }}</span>
                      <span class="accordion-summary-text">{{ item.app_count }} Apps{% if item.machine_count %} | {{ item.machine_count }} Machines{% endif %}</span>
                    </div>
                    <div class="accordion-subtitle">Profile sequence</div>
                  </div>
                  <span class="accordion-chevron" aria-hidden="true">
                    <svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>
                  </span>
                </button>
                {% if can_modify %}
                <div class="summary-actions">
                  <a class="icon-btn" href="{{ url_for('types.type_edit', type_name=item.type) }}" aria-label="Edit {{ item.type }}">
                    <svg viewBox="0 0 24 24"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z"/></svg>
                  </a>
                  <form method="post" action="{{ url_for('types.type_delete', type_name=item.type) }}" class="d-inline">
                    <button class="icon-btn icon-btn-danger js-delete"
                            type="button"
                            aria-label="Delete {{ item.type }}"
                            data-type="{{ item.type }}"
                            data-inuse="{{ count_by_type.get(item.type, 0) }}">
                      <svg viewBox="0 0 24 24"><path d="M3 6h18"/><path d="M8 6l1-2h6l1 2"/><path d="M6 6l1 14h10l1-14"/><path d="M10 10v6"/><path d="M14 10v6"/></svg>
                    </button>
                  </form>
                </div>
                {% endif %}
              </div>
              <div class="accordion-panel">
                {% if item.sequence|length > 0 %}
                <div class="mapping-list">
                  {% for it in item.sequence %}
                  <div class="mapping-item">
                    <div class="mapping-item-main">
                      <span class="mapping-item-icon" aria-hidden="true">&#128230;</span>
                      <div class="mapping-item-copy">
                        <div class="mapping-item-title">{{ it.name }}</div>
                        <div class="mapping-item-meta">
                          {% if it.reboot %}<span class="status-badge status-warning">Reboot</span>{% endif %}
                        </div>
                        {% if it.url %}
                        <div class="mapping-link">{{ it.url }}</div>
                        {% endif %}
                      </div>
                    </div>
                    {% if can_modify %}
                    <a class="mapping-open" href="{{ url_for('apps.app_edit', app_name=it.name) }}">Open</a>
                    {% endif %}
                  </div>
                  {% endfor %}
                </div>
                {% else %}
                <div class="empty-note">[no app for this profile yet]</div>
                {% endif %}
              </div>
            </div>
          </section>
          {% endfor %}
          {% else %}
          <section class="mapping-block block-profile">
            <div class="empty-note">[no profile found]</div>
          </section>
          {% endif %}


        </div>

      </div>

      <div id="deleteBackdrop" class="modal-backdrop"></div>
      <div id="deleteModal" class="modal-card" aria-hidden="true">
        <div class="modal-box">
          <div class="modal-title" id="deleteTitle">Delete type</div>
          <div class="modal-text" id="deleteMessage"></div>
          <div class="modal-muted small mt-2" id="deleteHint"></div>
          <div class="d-flex gap-2 mt-3">
            <button class="btn btn-danger" id="deleteConfirm" type="button"><svg viewBox="0 0 24 24" aria-hidden="true" style="width:16px;height:16px;vertical-align:-2px;margin-right:.35rem;" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6l1-2h6l1 2"/><path d="M6 6l1 14h10l1-14"/><path d="M10 10v6"/><path d="M14 10v6"/></svg></button>
            <button class="btn btn-secondary" id="deleteCancel" type="button">Cancel</button>
          </div>
        </div>
      </div>

      <script>
      (function(){
        document.querySelectorAll('[data-accordion-trigger]').forEach(function(trigger){
          trigger.addEventListener('click', function(){
            var entry = trigger.closest('[data-accordion]');
            if (!entry) return;
            var isOpen = entry.classList.toggle('is-open');
            trigger.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
          });
        });

        var buttons = document.querySelectorAll('.js-delete');
        var modal = document.getElementById('deleteModal');
        var backdrop = document.getElementById('deleteBackdrop');
        var title = document.getElementById('deleteTitle');
        var msg = document.getElementById('deleteMessage');
        var hint = document.getElementById('deleteHint');
        var btnConfirm = document.getElementById('deleteConfirm');
        var btnCancel = document.getElementById('deleteCancel');

        var activeForm = null;

        function openModal(){
          modal.style.display = 'flex';
          backdrop.style.display = 'block';
          modal.setAttribute('aria-hidden', 'false');
        }
        function closeModal(){
          modal.style.display = 'none';
          backdrop.style.display = 'none';
          modal.setAttribute('aria-hidden', 'true');
          activeForm = null;
        }

        buttons.forEach(function(btn){
          btn.addEventListener('click', function(ev){
            ev.preventDefault();
            ev.stopPropagation();
            if (!modal || !backdrop || !title || !msg || !hint || !btnConfirm || !btnCancel) return;

            var t = btn.getAttribute('data-type') || '';
            var inUse = parseInt(btn.getAttribute('data-inuse') || '0', 10);
            activeForm = btn.closest('form');

            title.textContent = 'Delete type "' + t + '"';
            if (inUse > 0) {
              msg.textContent = 'This type is still assigned to ' + inUse + ' machine(s).';
              hint.textContent = 'Update those machines first, then you can delete the type.';
              btnConfirm.style.display = 'none';
            } else {
              msg.textContent = 'Are you sure you want to delete this type and its app/config mapping?';
              hint.textContent = '';
              btnConfirm.style.display = '';
            }
            openModal();
          });
        });

        if (btnConfirm) {
          btnConfirm.addEventListener('click', function(){
            if (activeForm) activeForm.submit();
          });
        }
        if (btnCancel) btnCancel.addEventListener('click', closeModal);
        if (backdrop) backdrop.addEventListener('click', closeModal);
        document.addEventListener('keydown', function(e){
          if (e.key === 'Escape') closeModal();
        });
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(
            tmpl,
            special_base=special_base,
            special_finalize=special_finalize,
            normal_types=normal_types,
            count_by_type=count_by_type,
            can_modify=can_modify,
        )


    # ---------------------------------------------------------------------------
    # Add — admin/operator
    # ---------------------------------------------------------------------------
    @bp.route("/type/add", methods=["GET", "POST"])
    @require_roles('admin', 'operator')
    def type_add():
        conn = get_db()
        ensure_postype_catalog(conn)

        if request.method == "POST":
            t = request.form.get("type_name", "").strip().upper()
            if t == "" or t.upper() in RESERVED_GLOBAL:
                conn.close()
                abort(400, "invalid or reserved type")

            all_apps = conn.execute("SELECT name FROM apps ORDER BY name ASC;").fetchall()
            conn.execute("DELETE FROM postype_relations WHERE UPPER(TRIM(IFNULL(postype, ''))) = ?;", (t,))
            selected_apps = []
            for a in all_apps:
                app_name = str(a["name"])
                if request.form.get(f"use_app_{app_name}"):
                    order_raw = request.form.get(f"order_{app_name}", "1000").strip()
                    try:
                        order_int = int(order_raw)
                    except Exception:
                        order_int = 1000
                    selected_apps.append((order_int, app_name))
            for _, app_name in sorted(selected_apps, key=lambda item: (item[0], item[1].lower())):
                conn.execute("INSERT INTO postype_relations (postype, application) VALUES (?, ?);", (t, app_name))
            if not selected_apps:
                conn.execute("INSERT INTO postype_relations (postype, application) VALUES (?, '');", (t,))
            conn.commit()
            conn.close()
            return redirect(url_for("types.type_list"))

        all_apps = conn.execute("SELECT name, url FROM apps ORDER BY name ASC;").fetchall()
        conn.close()

        return _render_type_mapping_editor(
            type_name="",
            is_new=True,
            apps_rows=all_apps,
            selected_app_orders={},
        )

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Add Type Mapping</title>
    __HEAD_ASSETS__
      <style>
        :root{ --bg:#0b1220; --panel:#121a2b; --panel-2:#0f1726;
          --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06);
          --heading:#dbe8ff; --link:#b9d8ff; --accent:#3fa7ff; }
        body{background:var(--bg); color:var(--text)}
        h1{color:var(--heading)!important}
        .card{background:var(--panel); border:1px solid var(--border)}
        .form-label{color:var(--heading)!important; font-weight:700}
        .form-control,.form-select,textarea{background:var(--panel-2); color:var(--text); border:1px solid var(--border)}
        .form-control:focus,.form-select:focus,textarea:focus{border-color:#29406b; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)}
        .form-text{color:#cfe1ff; font-weight:600}
        .helper{color:#cfe1ff; font-weight:600}
        .transfer-grid{
          display:grid;
          grid-template-columns:1fr auto 1fr;
          gap:1rem;
          align-items:start;
        }
        .transfer-pane{
          background:var(--panel-2);
          border:1px solid var(--border);
          border-radius:.75rem;
          padding:.75rem;
          min-height:480px;
        }
        .transfer-head{
          display:flex;
          justify-content:space-between;
          align-items:center;
          gap:.6rem;
          margin-bottom:.6rem;
          flex-wrap:wrap;
        }
        .transfer-title{
          color:var(--heading);
          font-weight:700;
          margin:0;
        }
        .filter-input{
          background:var(--panel-2);
          color:var(--text);
          border:1px solid var(--border);
          min-width:180px;
        }
        .filter-input::placeholder{
          color:var(--muted);
          opacity:1;
        }
        .transfer-list{
          margin:0;
          padding:0;
          list-style:none;
          display:flex;
          flex-direction:column;
          gap:.45rem;
          max-height:420px;
          overflow:auto;
        }
        .transfer-item{
          border:1px solid var(--border);
          border-radius:.6rem;
          padding:.5rem .65rem;
          background:rgba(255,255,255,.02);
          cursor:pointer;
          user-select:none;
        }
        .transfer-item:hover{border-color:#2b3d5c}
        .transfer-item.is-active{
          border-color:var(--accent);
          background:rgba(63,167,255,.15);
        }
        .transfer-item.dragging{opacity:.55}
        .item-main{
          display:flex;
          align-items:center;
          gap:.45rem;
          min-width:0;
        }
        .drag-handle{
          display:none;
          color:var(--muted);
          font-weight:700;
          cursor:grab;
          line-height:1;
        }
        #selectedList .drag-handle{display:inline-block}
        .app-name{
          color:var(--text);
          font-weight:600;
          min-width:0;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
        }
        .app-icon{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          font-size:.95rem;
          line-height:1;
          flex:0 0 auto;
        }
        .transfer-actions{
          display:flex;
          flex-direction:column;
          gap:.55rem;
          justify-content:center;
          align-items:center;
          min-height:480px;
        }
        .transfer-actions .btn{
          width:46px;
          height:42px;
          font-size:1.15rem;
          font-weight:700;
        }
        .empty-tip{
          color:var(--muted);
          font-size:.9rem;
          text-align:center;
          padding:.55rem .25rem .2rem;
        }
        @media (max-width: 992px){
          .transfer-grid{grid-template-columns:1fr}
          .transfer-actions{
            flex-direction:row;
            min-height:auto;
            padding:.25rem 0;
          }
          .transfer-actions .btn{
            width:52px;
          }
        }
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <h1 class="mb-4">Add Type Mapping</h1>

        <form id="mappingForm" method="post" class="card shadow-sm p-3">
          <div class="mb-3">
            <label class="form-label">Type</label>
            <input type="text" name="type_name" class="form-control" required>
            <div class="form-text">
              Examples: <code>POS_A</code>, <code>STORE_B</code> -
              <b>Reserved:</b> <code>BASE</code>, <code>FINALIZE</code> (global stacks).
            </div>
          </div>

          <div class="mb-2">
            <p class="helper mb-0">Transfer List: move apps between Available and Selected using <b>&gt;</b> and <b>&lt;</b>.</p>
          </div>

          <div class="transfer-grid mb-3">
            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Available Apps</p>
                <input type="text" id="availableFilter" class="form-control form-control-sm filter-input" placeholder="Filter available...">
              </div>
              <ul id="availableList" class="transfer-list">
                {% for app in all_apps %}
                <li class="transfer-item" data-search="{{ (app.name or '')|lower }}" draggable="false">
                  <div class="item-main">
                    <span class="drag-handle">::</span>
                    <span class="app-icon" aria-hidden="true">&#128230;</span>
                    <span class="app-name">{{ app.name }}</span>
                  </div>
                  <input class="use-app" type="checkbox" name="use_app_{{ app.id }}" value="1" hidden>
                  <input class="order-input" type="hidden" name="order_{{ app.id }}" value="1000">
                </li>
                {% endfor %}
              </ul>
              {% if all_apps|length == 0 %}
              <div class="empty-tip">No apps in catalog</div>
              {% endif %}
            </section>

            <div class="transfer-actions">
              <button id="btnTransfer" class="btn btn-primary" type="button" title="Move" disabled>&gt;</button>
            </div>

            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Selected Apps (<span id="selectedCount">0</span>)</p>
                <input type="text" id="selectedFilter" class="form-control form-control-sm filter-input" placeholder="Filter selected...">
              </div>
              <ul id="selectedList" class="transfer-list"></ul>
              <div id="selectedEmpty" class="empty-tip">No selected apps</div>
            </section>
          </div>

          <div class="mb-2">
            <p class="helper mb-0">Transfer List: move configurations between Available and Selected using <b>&gt;</b> and <b>&lt;</b>.</p>
          </div>
          <div class="transfer-grid mb-3">
            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Available Configuration</p>
                <input type="text" id="availableCfgFilter" class="form-control form-control-sm filter-input" placeholder="Filter available...">
              </div>
              <ul id="availableCfgList" class="transfer-list">
                {% for cfg in all_configs %}
                <li class="transfer-item" data-search="{{ (cfg.name or '')|lower }}" draggable="false">
                  <div class="item-main">
                    <span class="drag-handle">::</span>
                    <span class="app-icon" aria-hidden="true">&#9881;</span>
                    <span class="app-name">{{ cfg.name }}</span>
                  </div>
                  <input class="use-app" type="checkbox" name="use_cfg_{{ cfg.id }}" value="1" hidden>
                  <input class="order-input" type="hidden" name="order_cfg_{{ cfg.id }}" value="1000">
                </li>
                {% endfor %}
              </ul>
              {% if all_configs|length == 0 %}
              <div class="empty-tip">No configuration in catalog</div>
              {% endif %}
            </section>

            <div class="transfer-actions">
              <button id="btnTransferCfg" class="btn btn-primary" type="button" title="Move" disabled>&gt;</button>
            </div>

            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Selected Configuration (<span id="selectedCfgCount">0</span>)</p>
                <input type="text" id="selectedCfgFilter" class="form-control form-control-sm filter-input" placeholder="Filter selected...">
              </div>
              <ul id="selectedCfgList" class="transfer-list"></ul>
              <div id="selectedCfgEmpty" class="empty-tip">No selected configuration</div>
            </section>
          </div>

          <div class="d-flex gap-2">
            <button class="btn btn-success" type="submit">Save</button>
            <a class="btn btn-secondary" href="{{ url_for('types.type_list') }}">Cancel</a>
          </div>
        </form>

      </div>

      <script>
      (function(){
        var form = document.getElementById('mappingForm');
        if (!form) return;

        function setupTransfer(opts){
          var availableList = document.getElementById(opts.availableListId);
          var selectedList = document.getElementById(opts.selectedListId);
          var btnTransfer = document.getElementById(opts.buttonId);
          var availableFilter = document.getElementById(opts.availableFilterId);
          var selectedFilter = document.getElementById(opts.selectedFilterId);
          var selectedCount = document.getElementById(opts.selectedCountId);
          var selectedEmpty = document.getElementById(opts.selectedEmptyId);
          if (!availableList || !selectedList || !btnTransfer) return function(){};

          var dragItem = null;

          function listItems(list){
            return Array.prototype.slice.call(list.querySelectorAll('.transfer-item'));
          }

          function clearActive(except){
            listItems(availableList).concat(listItems(selectedList)).forEach(function(item){
              if (item !== except){
                item.classList.remove('is-active');
              }
            });
            updateActionButtons();
          }

          function updateActionButtons(){
            var active = availableList.querySelector('.transfer-item.is-active') || selectedList.querySelector('.transfer-item.is-active');
            if (!active){
              btnTransfer.disabled = true;
              btnTransfer.textContent = '>';
              btnTransfer.title = 'Select an item first';
              return;
            }
            var inAvailable = active.parentElement === availableList;
            btnTransfer.disabled = false;
            btnTransfer.textContent = inAvailable ? '>' : '<';
            btnTransfer.title = inAvailable ? 'Move to selected' : 'Remove from selected';
          }

          function bindItem(item){
            item.addEventListener('click', function(){
              clearActive(item);
              item.classList.add('is-active');
              updateActionButtons();
            });

            item.addEventListener('dblclick', function(){
              clearActive(item);
              item.classList.add('is-active');
              updateActionButtons();
              if (item.parentElement === availableList){
                moveSelected(availableList, selectedList);
              } else if (item.parentElement === selectedList){
                moveSelected(selectedList, availableList);
              }
            });
          }

          listItems(availableList).concat(listItems(selectedList)).forEach(bindItem);

          function applyFilter(list, input){
            var q = ((input && input.value) || '').toLowerCase().trim();
            listItems(list).forEach(function(item){
              var txt = item.dataset.search || '';
              item.style.display = (!q || txt.indexOf(q) !== -1) ? '' : 'none';
            });
          }

          function syncInputs(){
            listItems(availableList).forEach(function(item){
              var use = item.querySelector('.use-app');
              var ord = item.querySelector('.order-input');
              if (use) use.checked = false;
              if (ord) ord.value = '1000';
              item.draggable = false;
            });
            listItems(selectedList).forEach(function(item, idx){
              var use = item.querySelector('.use-app');
              var ord = item.querySelector('.order-input');
              if (use) use.checked = true;
              if (ord) ord.value = String((idx + 1) * 10);
              item.draggable = true;
            });
          }

          function refreshSelectedMeta(){
            var n = listItems(selectedList).length;
            if (selectedCount) selectedCount.textContent = String(n);
            if (selectedEmpty) selectedEmpty.style.display = n ? 'none' : '';
          }

          function moveSelected(source, target){
            var moving = source.querySelector('.transfer-item.is-active');
            if (!moving) return;
            moving.classList.remove('is-active');
            target.appendChild(moving);

            syncInputs();
            refreshSelectedMeta();
            applyFilter(source, source === availableList ? availableFilter : selectedFilter);
            applyFilter(target, target === availableList ? availableFilter : selectedFilter);
            updateActionButtons();
          }

          btnTransfer.addEventListener('click', function(){
            var active = availableList.querySelector('.transfer-item.is-active') || selectedList.querySelector('.transfer-item.is-active');
            if (!active) return;
            if (active.parentElement === availableList){
              moveSelected(availableList, selectedList);
            } else {
              moveSelected(selectedList, availableList);
            }
          });

          if (availableFilter){
            availableFilter.addEventListener('input', function(){
              applyFilter(availableList, availableFilter);
            });
          }
          if (selectedFilter){
            selectedFilter.addEventListener('input', function(){
              applyFilter(selectedList, selectedFilter);
            });
          }

          selectedList.addEventListener('dragstart', function(e){
            var item = e.target.closest('.transfer-item');
            if (!item) return;
            dragItem = item;
            item.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
          });

          selectedList.addEventListener('dragover', function(e){
            if (!dragItem) return;
            e.preventDefault();
            var target = e.target.closest('.transfer-item');
            if (!target || target === dragItem) return;
            var rect = target.getBoundingClientRect();
            var after = (e.clientY - rect.top) > (rect.height / 2);
            selectedList.insertBefore(dragItem, after ? target.nextSibling : target);
          });

          selectedList.addEventListener('drop', function(e){
            if (!dragItem) return;
            e.preventDefault();
            syncInputs();
            refreshSelectedMeta();
          });

          selectedList.addEventListener('dragend', function(){
            if (!dragItem) return;
            dragItem.classList.remove('dragging');
            dragItem = null;
            syncInputs();
            refreshSelectedMeta();
          });

          syncInputs();
          refreshSelectedMeta();
          updateActionButtons();
          return syncInputs;
        }

        var syncFns = [];
        syncFns.push(setupTransfer({
          availableListId: 'availableList',
          selectedListId: 'selectedList',
          buttonId: 'btnTransfer',
          availableFilterId: 'availableFilter',
          selectedFilterId: 'selectedFilter',
          selectedCountId: 'selectedCount',
          selectedEmptyId: 'selectedEmpty'
        }));
        syncFns.push(setupTransfer({
          availableListId: 'availableCfgList',
          selectedListId: 'selectedCfgList',
          buttonId: 'btnTransferCfg',
          availableFilterId: 'availableCfgFilter',
          selectedFilterId: 'selectedCfgFilter',
          selectedCountId: 'selectedCfgCount',
          selectedEmptyId: 'selectedCfgEmpty'
        }));

        form.addEventListener('submit', function(){
          syncFns.forEach(function(fn){
            if (typeof fn === 'function') fn();
          });
        });
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(tmpl, all_apps=all_apps, all_configs=all_configs)


    # ---------------------------------------------------------------------------
    # Edit — admin/operator (BASE/FINALIZE + types spécifiques)
    # ---------------------------------------------------------------------------
    @bp.route("/type/<type_name>/edit", methods=["GET", "POST"])
    @require_roles('admin', 'operator')
    def type_edit(type_name):
        if type_name == EMPTY_TYPE_TOKEN:
            abort(400, "cannot edit empty type")
        t = type_name.strip().upper()
        if t == "":
            abort(400, "invalid type")

        conn = get_db()
        ensure_postype_catalog(conn)

        if request.method == "POST":
            conn.execute("DELETE FROM postype_relations WHERE UPPER(TRIM(IFNULL(postype, ''))) = ?;", (t,))
            all_apps = conn.execute("SELECT name FROM apps ORDER BY name ASC;").fetchall()
            selected_apps = []
            for a in all_apps:
                app_name = str(a["name"])
                if request.form.get(f"use_app_{app_name}"):
                    order_raw = request.form.get(f"order_{app_name}", "1000").strip()
                    try:
                        order_int = int(order_raw)
                    except Exception:
                        order_int = 1000
                    selected_apps.append((order_int, app_name))
            for _, app_name in sorted(selected_apps, key=lambda item: (item[0], item[1].lower())):
                conn.execute("INSERT INTO postype_relations (postype, application) VALUES (?, ?);", (t, app_name))
            if not selected_apps:
                conn.execute("INSERT INTO postype_relations (postype, application) VALUES (?, '');", (t,))
            conn.commit()
            conn.close()
            return redirect(url_for("types.type_list"))

        all_apps = conn.execute("SELECT name, url FROM apps ORDER BY name ASC;").fetchall()
        linked_rows = conn.execute(
            """
            SELECT a.name AS app_name, (pr.rowid + 1) * 10 AS sort_order
            FROM postype_relations pr
            JOIN apps a ON a.name = pr.application
            WHERE UPPER(TRIM(IFNULL(pr.postype, ''))) = ? AND TRIM(IFNULL(pr.application, '')) <> ''
            ORDER BY pr.rowid;
            """,
            (t,),
        ).fetchall()
        conn.close()

        linked_app_orders = {
            str(r["app_name"]): int(r["sort_order"] if r["sort_order"] is not None else 1000)
            for r in linked_rows
        }
        return _render_type_mapping_editor(
            type_name=t,
            is_new=False,
            apps_rows=all_apps,
            selected_app_orders=linked_app_orders,
        )

        linked_info = {
            r["app_id"]: (r["sort_order"] if r["sort_order"] is not None else 1000)
            for r in linked_rows
        }
        app_models = []
        for a in all_apps:
            aid = a["id"]
            app_models.append({
                "id": aid,
                "name": a["name"],
                "url": a["url"],
                "selected": aid in linked_info,
                "order": linked_info.get(aid, 1000),
            })

        selected_apps = sorted(
            [x for x in app_models if x["selected"]],
            key=lambda x: (x["order"], (x["name"] or "").lower()),
        )
        available_apps = sorted(
            [x for x in app_models if not x["selected"]],
            key=lambda x: ((x["name"] or "").lower()),
        )

        linked_cfg_info = {
            r["config_id"]: (r["sort_order"] if r["sort_order"] is not None else 1000)
            for r in linked_cfg_rows
        }
        cfg_models = []
        for c in all_cfgs:
            cid = c["id"]
            cfg_models.append({
                "id": cid,
                "name": c["name"],
                "url": c["url"],
                "selected": cid in linked_cfg_info,
                "order": linked_cfg_info.get(cid, 1000),
            })
        selected_cfgs = sorted(
            [x for x in cfg_models if x["selected"]],
            key=lambda x: (x["order"], (x["name"] or "").lower()),
        )
        available_cfgs = sorted(
            [x for x in cfg_models if not x["selected"]],
            key=lambda x: ((x["name"] or "").lower()),
        )

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Edit Type Mapping</title>
    __HEAD_ASSETS__
      <style>
        :root{ --bg:#0b1220; --panel:#121a2b; --panel-2:#0f1726;
          --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06);
          --heading:#dbe8ff; --link:#b9d8ff; --accent:#3fa7ff; }
        body{background:var(--bg); color:var(--text)}
        h1{color:var(--heading)!important}
        .card{background:var(--panel); border:1px solid var(--border)}
        .form-control,.form-select,textarea{background:var(--panel-2); color:var(--text); border:1px solid var(--border)}
        .form-control:focus,.form-select:focus,textarea:focus{border-color:#29406b; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)}
        .helper{color:#cfe1ff; font-weight:600}
        .transfer-grid{
          display:grid;
          grid-template-columns:1fr auto 1fr;
          gap:1rem;
          align-items:start;
        }
        .transfer-pane{
          background:var(--panel-2);
          border:1px solid var(--border);
          border-radius:.75rem;
          padding:.75rem;
          min-height:500px;
        }
        .transfer-head{
          display:flex;
          justify-content:space-between;
          align-items:center;
          gap:.6rem;
          margin-bottom:.6rem;
          flex-wrap:wrap;
        }
        .transfer-title{
          color:var(--heading);
          font-weight:700;
          margin:0;
        }
        .filter-input{
          background:var(--panel-2);
          color:var(--text);
          border:1px solid var(--border);
          min-width:180px;
        }
        .filter-input::placeholder{
          color:var(--muted);
          opacity:1;
        }
        .transfer-list{
          margin:0;
          padding:0;
          list-style:none;
          display:flex;
          flex-direction:column;
          gap:.45rem;
          max-height:430px;
          overflow:auto;
        }
        .transfer-item{
          border:1px solid var(--border);
          border-radius:.6rem;
          padding:.5rem .65rem;
          background:rgba(255,255,255,.02);
          cursor:pointer;
          user-select:none;
        }
        .transfer-item:hover{border-color:#2b3d5c}
        .transfer-item.is-active{
          border-color:var(--accent);
          background:rgba(63,167,255,.15);
        }
        .transfer-item.dragging{opacity:.55}
        .item-main{
          display:flex;
          align-items:center;
          gap:.45rem;
          min-width:0;
        }
        .drag-handle{
          display:none;
          color:var(--muted);
          font-weight:700;
          cursor:grab;
          line-height:1;
        }
        #selectedList .drag-handle{display:inline-block}
        .app-name{
          color:var(--text);
          font-weight:600;
          min-width:0;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
        }
        .app-icon{
          display:inline-flex;
          align-items:center;
          justify-content:center;
          font-size:.95rem;
          line-height:1;
          flex:0 0 auto;
        }
        .transfer-actions{
          display:flex;
          flex-direction:column;
          gap:.55rem;
          justify-content:center;
          align-items:center;
          min-height:500px;
        }
        .transfer-actions .btn{
          width:46px;
          height:42px;
          font-size:1.15rem;
          font-weight:700;
        }
        .empty-tip{
          color:var(--muted);
          font-size:.9rem;
          text-align:center;
          padding:.55rem .25rem .2rem;
        }
        @media (max-width: 992px){
          .transfer-grid{grid-template-columns:1fr}
          .transfer-actions{
            flex-direction:row;
            min-height:auto;
            padding:.25rem 0;
          }
          .transfer-actions .btn{
            width:52px;
          }
        }
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <h1 class="mb-4">Edit Mapping for "{{ type_name }}"</h1>

        <form id="mappingForm" method="post" class="card shadow-sm p-3">
          <div class="mb-2">
            <p class="helper mb-0">Transfer List: move apps between Available and Selected using <b>&gt;</b> and <b>&lt;</b>.</p>
          </div>

          <div class="transfer-grid mb-3">
            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Available Apps</p>
                <input type="text" id="availableFilter" class="form-control form-control-sm filter-input" placeholder="Filter available...">
              </div>
              <ul id="availableList" class="transfer-list">
                {% for app in available_apps %}
                <li class="transfer-item" data-search="{{ (app.name or '')|lower }}" draggable="false">
                  <div class="item-main">
                    <span class="drag-handle">::</span>
                    <span class="app-icon" aria-hidden="true">&#128230;</span>
                    <span class="app-name">{{ app.name }}</span>
                  </div>
                  <input class="use-app" type="checkbox" name="use_app_{{ app.id }}" value="1" hidden>
                  <input class="order-input" type="hidden" name="order_{{ app.id }}" value="1000">
                </li>
                {% endfor %}
              </ul>
              {% if available_apps|length == 0 %}
              <div class="empty-tip">No available apps</div>
              {% endif %}
            </section>

            <div class="transfer-actions">
              <button id="btnTransfer" class="btn btn-primary" type="button" title="Move" disabled>&gt;</button>
            </div>

            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Selected Apps (<span id="selectedCount">{{ selected_apps|length }}</span>)</p>
                <input type="text" id="selectedFilter" class="form-control form-control-sm filter-input" placeholder="Filter selected...">
              </div>
              <ul id="selectedList" class="transfer-list">
                {% for app in selected_apps %}
                <li class="transfer-item" data-search="{{ (app.name or '')|lower }}" draggable="true">
                  <div class="item-main">
                    <span class="drag-handle">::</span>
                    <span class="app-icon" aria-hidden="true">&#128230;</span>
                    <span class="app-name">{{ app.name }}</span>
                  </div>
                  <input class="use-app" type="checkbox" name="use_app_{{ app.id }}" value="1" checked hidden>
                  <input class="order-input" type="hidden" name="order_{{ app.id }}" value="{{ app.order }}">
                </li>
                {% endfor %}
              </ul>
              <div id="selectedEmpty" class="empty-tip" {% if selected_apps|length > 0 %}style="display:none"{% endif %}>No selected apps</div>
            </section>
          </div>

          <div class="mb-2">
            <p class="helper mb-0">Transfer List: move configurations between Available and Selected using <b>&gt;</b> and <b>&lt;</b>.</p>
          </div>
          <div class="transfer-grid mb-3">
            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Available Configuration</p>
                <input type="text" id="availableCfgFilter" class="form-control form-control-sm filter-input" placeholder="Filter available...">
              </div>
              <ul id="availableCfgList" class="transfer-list">
                {% for cfg in available_cfgs %}
                <li class="transfer-item" data-search="{{ (cfg.name or '')|lower }}" draggable="false">
                  <div class="item-main">
                    <span class="drag-handle">::</span>
                    <span class="app-icon" aria-hidden="true">&#9881;</span>
                    <span class="app-name">{{ cfg.name }}</span>
                  </div>
                  <input class="use-app" type="checkbox" name="use_cfg_{{ cfg.id }}" value="1" hidden>
                  <input class="order-input" type="hidden" name="order_cfg_{{ cfg.id }}" value="1000">
                </li>
                {% endfor %}
              </ul>
              {% if available_cfgs|length == 0 %}
              <div class="empty-tip">No available configuration</div>
              {% endif %}
            </section>

            <div class="transfer-actions">
              <button id="btnTransferCfg" class="btn btn-primary" type="button" title="Move" disabled>&gt;</button>
            </div>

            <section class="transfer-pane">
              <div class="transfer-head">
                <p class="transfer-title">Selected Configuration (<span id="selectedCfgCount">{{ selected_cfgs|length }}</span>)</p>
                <input type="text" id="selectedCfgFilter" class="form-control form-control-sm filter-input" placeholder="Filter selected...">
              </div>
              <ul id="selectedCfgList" class="transfer-list">
                {% for cfg in selected_cfgs %}
                <li class="transfer-item" data-search="{{ (cfg.name or '')|lower }}" draggable="true">
                  <div class="item-main">
                    <span class="drag-handle">::</span>
                    <span class="app-icon" aria-hidden="true">&#9881;</span>
                    <span class="app-name">{{ cfg.name }}</span>
                  </div>
                  <input class="use-app" type="checkbox" name="use_cfg_{{ cfg.id }}" value="1" checked hidden>
                  <input class="order-input" type="hidden" name="order_cfg_{{ cfg.id }}" value="{{ cfg.order }}">
                </li>
                {% endfor %}
              </ul>
              <div id="selectedCfgEmpty" class="empty-tip" {% if selected_cfgs|length > 0 %}style="display:none"{% endif %}>No selected configuration</div>
            </section>
          </div>

          <div class="d-flex gap-2">
            <button class="btn btn-primary" type="submit">Save</button>
            <a class="btn btn-secondary" href="{{ url_for('types.type_list') }}">Cancel</a>
          </div>
        </form>

      </div>

      <script>
      (function(){
        var form = document.getElementById('mappingForm');
        if (!form) return;

        function setupTransfer(opts){
          var availableList = document.getElementById(opts.availableListId);
          var selectedList = document.getElementById(opts.selectedListId);
          var btnTransfer = document.getElementById(opts.buttonId);
          var availableFilter = document.getElementById(opts.availableFilterId);
          var selectedFilter = document.getElementById(opts.selectedFilterId);
          var selectedCount = document.getElementById(opts.selectedCountId);
          var selectedEmpty = document.getElementById(opts.selectedEmptyId);
          if (!availableList || !selectedList || !btnTransfer) return function(){};

          var dragItem = null;

          function listItems(list){
            return Array.prototype.slice.call(list.querySelectorAll('.transfer-item'));
          }

          function clearActive(except){
            listItems(availableList).concat(listItems(selectedList)).forEach(function(item){
              if (item !== except){
                item.classList.remove('is-active');
              }
            });
            updateActionButtons();
          }

          function updateActionButtons(){
            var active = availableList.querySelector('.transfer-item.is-active') || selectedList.querySelector('.transfer-item.is-active');
            if (!active){
              btnTransfer.disabled = true;
              btnTransfer.textContent = '>';
              btnTransfer.title = 'Select an item first';
              return;
            }
            var inAvailable = active.parentElement === availableList;
            btnTransfer.disabled = false;
            btnTransfer.textContent = inAvailable ? '>' : '<';
            btnTransfer.title = inAvailable ? 'Move to selected' : 'Remove from selected';
          }

          function bindItem(item){
            item.addEventListener('click', function(){
              clearActive(item);
              item.classList.add('is-active');
              updateActionButtons();
            });

            item.addEventListener('dblclick', function(){
              clearActive(item);
              item.classList.add('is-active');
              updateActionButtons();
              if (item.parentElement === availableList){
                moveSelected(availableList, selectedList);
              } else if (item.parentElement === selectedList){
                moveSelected(selectedList, availableList);
              }
            });
          }

          listItems(availableList).concat(listItems(selectedList)).forEach(bindItem);

          function applyFilter(list, input){
            var q = ((input && input.value) || '').toLowerCase().trim();
            listItems(list).forEach(function(item){
              var txt = item.dataset.search || '';
              item.style.display = (!q || txt.indexOf(q) !== -1) ? '' : 'none';
            });
          }

          function syncInputs(){
            listItems(availableList).forEach(function(item){
              var use = item.querySelector('.use-app');
              var ord = item.querySelector('.order-input');
              if (use) use.checked = false;
              if (ord) ord.value = '1000';
              item.draggable = false;
            });
            listItems(selectedList).forEach(function(item, idx){
              var use = item.querySelector('.use-app');
              var ord = item.querySelector('.order-input');
              if (use) use.checked = true;
              if (ord) ord.value = String((idx + 1) * 10);
              item.draggable = true;
            });
          }

          function refreshSelectedMeta(){
            var n = listItems(selectedList).length;
            if (selectedCount) selectedCount.textContent = String(n);
            if (selectedEmpty) selectedEmpty.style.display = n ? 'none' : '';
          }

          function moveSelected(source, target){
            var moving = source.querySelector('.transfer-item.is-active');
            if (!moving) return;
            moving.classList.remove('is-active');
            target.appendChild(moving);

            syncInputs();
            refreshSelectedMeta();
            applyFilter(source, source === availableList ? availableFilter : selectedFilter);
            applyFilter(target, target === availableList ? availableFilter : selectedFilter);
            updateActionButtons();
          }

          btnTransfer.addEventListener('click', function(){
            var active = availableList.querySelector('.transfer-item.is-active') || selectedList.querySelector('.transfer-item.is-active');
            if (!active) return;
            if (active.parentElement === availableList){
              moveSelected(availableList, selectedList);
            } else {
              moveSelected(selectedList, availableList);
            }
          });

          if (availableFilter){
            availableFilter.addEventListener('input', function(){
              applyFilter(availableList, availableFilter);
            });
          }
          if (selectedFilter){
            selectedFilter.addEventListener('input', function(){
              applyFilter(selectedList, selectedFilter);
            });
          }

          selectedList.addEventListener('dragstart', function(e){
            var item = e.target.closest('.transfer-item');
            if (!item) return;
            dragItem = item;
            item.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
          });

          selectedList.addEventListener('dragover', function(e){
            if (!dragItem) return;
            e.preventDefault();
            var target = e.target.closest('.transfer-item');
            if (!target || target === dragItem) return;
            var rect = target.getBoundingClientRect();
            var after = (e.clientY - rect.top) > (rect.height / 2);
            selectedList.insertBefore(dragItem, after ? target.nextSibling : target);
          });

          selectedList.addEventListener('drop', function(e){
            if (!dragItem) return;
            e.preventDefault();
            syncInputs();
            refreshSelectedMeta();
          });

          selectedList.addEventListener('dragend', function(){
            if (!dragItem) return;
            dragItem.classList.remove('dragging');
            dragItem = null;
            syncInputs();
            refreshSelectedMeta();
          });

          syncInputs();
          refreshSelectedMeta();
          updateActionButtons();
          return syncInputs;
        }

        var syncFns = [];
        syncFns.push(setupTransfer({
          availableListId: 'availableList',
          selectedListId: 'selectedList',
          buttonId: 'btnTransfer',
          availableFilterId: 'availableFilter',
          selectedFilterId: 'selectedFilter',
          selectedCountId: 'selectedCount',
          selectedEmptyId: 'selectedEmpty'
        }));
        syncFns.push(setupTransfer({
          availableListId: 'availableCfgList',
          selectedListId: 'selectedCfgList',
          buttonId: 'btnTransferCfg',
          availableFilterId: 'availableCfgFilter',
          selectedFilterId: 'selectedCfgFilter',
          selectedCountId: 'selectedCfgCount',
          selectedEmptyId: 'selectedCfgEmpty'
        }));

        form.addEventListener('submit', function(){
          syncFns.forEach(function(fn){
            if (typeof fn === 'function') fn();
          });
        });
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(
            tmpl,
            type_name=t,
            available_apps=available_apps,
            selected_apps=selected_apps,
            available_cfgs=available_cfgs,
            selected_cfgs=selected_cfgs,
        )


    # ---------------------------------------------------------------------------
    # Delete — admin/operator
    # ---------------------------------------------------------------------------
    @bp.route("/type/<type_name>/delete", methods=["POST"])
    @require_roles('admin', 'operator')
    def type_delete(type_name):
        if type_name == EMPTY_TYPE_TOKEN:
            abort(400, "cannot delete this type")
        t = type_name.strip().upper()
        if t == "" or t.upper() in RESERVED_GLOBAL:
            abort(400, "cannot delete this type")

        conn = get_db()
        ensure_postype_catalog(conn)

        row = conn.execute("SELECT COUNT(*) AS c FROM newcomputer WHERE UPPER(TRIM(IFNULL(postype, ''))) = ?;", (t,)).fetchone()
        if row and row["c"] > 0:
            conn.close()
            abort(400, "type in use")

        conn.execute("DELETE FROM postype_relations WHERE UPPER(TRIM(IFNULL(postype, ''))) = ?;", (t,))
        conn.commit()
        conn.close()
        return redirect(url_for("types.type_list"))

    return bp


types_bp = _build_types_bp()
del _build_types_bp


# ========================================================================
# Progress blueprint, formerly bp_progress.py
# ========================================================================
def _build_progress_bp():
    """
    =============================================================================
    bp_progress.py - Deployment Progress Tracking Blueprint
    =============================================================================

    Tracks real-time deployment progress for each device.

    Features:
      - Monitor deployment steps and status
      - Display live progress indicators
      - Show deployment errors and warnings
      - Link to device logs
      - Deployment timeline view
    """

    import re
    import datetime
    from pathlib import Path
    from typing import Optional
    from flask import Blueprint, jsonify, url_for, request, redirect, session, current_app
    from core import get_db, get_logs_db, normalize_id, require_roles, render_inline

    bp = Blueprint("progress", __name__)

    STEP_RE = re.compile(r"\bSTEP\s+(\d{3})\b", re.IGNORECASE)
    PROFILE_RE = re.compile(r"CUSTOMER\s*-\s*\[([A-Z0-9_-]+)\]", re.IGNORECASE)
    END_PROVISION_RE = re.compile(
        r"^\s*(?:\[(?:INFO|OK|WARN|ERROR|SKIP)\]\s*)?END\s*PROVISION(?:ING|NING)?\s*$",
        re.IGNORECASE,
    )
    RUNNING_HOOK_RE = re.compile(
        r"running\s+endprovisionning\.ps1\b.*waiting\s+for\s+completion",
        re.IGNORECASE,
    )


    def _parse_dt(s: str):
        if not s:
          raise ValueError("Date string is required")
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S")


    def _format_td(td: Optional[datetime.timedelta]) -> str:
        if td is None:
          raise ValueError("Timedelta is required")
        total = int(td.total_seconds())
        h = total // 3600
        m = (total % 3600) // 60
        s = total % 60
        return f"{h:02d}:{m:02d}:{s:02d}"


    def _safe_logs_folder_name(name: str) -> str:
        if name is None:
          raise ValueError("name is required")
        s = name.strip()
        if not s or s in (".", ".."):
          raise ValueError("Invalid logs folder name")
        s = s.replace("/", "_").replace("\\", "_").replace(":", "_")
        s = "".join(ch for ch in s if ch.isalnum() or ch in ("-", "_", ".", " "))
        s = s.strip().strip(".")
        if not s or s in (".", ".."):
          raise ValueError("Invalid logs folder name")
        return s


    def _logs_href_for_computer(computer_name: str) -> str:
        base_href = url_for("files.list_dir")
        if not (computer_name or "").strip():
            return base_href
        try:
            subpath = _safe_logs_folder_name(computer_name)
        except ValueError:
            return base_href
        logs_root = (Path(current_app.root_path).resolve() / "logs").resolve()
        target = (logs_root / subpath).resolve()
        if target.exists() and target.is_dir() and target.parent == logs_root:
            return url_for("files.list_dir", subpath=subpath)
        return base_href


    def _is_end_provision(info: str) -> bool:
        return bool(END_PROVISION_RE.match((info or "").strip()))


    def _is_running_hook(info: str) -> bool:
        return bool(RUNNING_HOOK_RE.search((info or "").strip()))


    def _clean_profile(raw: str) -> str:
        value = (raw or "").strip()
        if not value:
          return "BASE"
        if value.upper() in ("EMPTY", "NONE", "NULL"):
          return "BASE"
        return value


    def _detect_profile(window, fallback_postype: str = "") -> str:
        if window is None:
          raise ValueError("window is required")
        for r in reversed(window):
          info = r["info"]
          upper = info.upper()
          if "NO TYPE PROVIDED" in upper:
            return "BASE"
          m = PROFILE_RE.search(info)
          if m:
            profile = m.group(1).strip().upper()
            if profile and profile not in ("BASE", "FINALIZE"):
              return profile
        if fallback_postype:
          return fallback_postype
        return "UNKNOWN"


    def _log_level(info: str) -> str:
        text = (info or "").strip()
        upper = text.upper()

        m = re.search(r"\[(INFO|OK|WARN|ERROR|SKIP)\]", upper)
        if m:
            level = m.group(1)
            if level == "ERROR":
                return "error"
            if level == "WARN":
                return "warning"
            if level == "OK":
                return "ok"
            return "info"

        if " WARNING" in upper or upper.startswith("WARNING"):
            return "warning"
        if " ERROR" in upper or upper.startswith("ERROR"):
            return "error"
        if "[OK]" in upper or "SUCCESS" in upper:
            return "ok"
        return "info"


    LOG_TAG_RE = re.compile(r"^\s*(\[(?:INFO|OK|WARN|WARNING|ERROR|SKIP)\])\s*(.*)$", re.IGNORECASE)


    def _split_log_tag(info: str):
        text = info or ""
        m = LOG_TAG_RE.match(text.strip())
        if not m:
            return "", text
        tag = (m.group(1) or "").strip().upper().replace("[WARNING]", "[WARN]")
        body = (m.group(2) or "").strip()
        return tag, body


    def _extract_issue_message(info: str, issue_kind: str) -> str:
        text = (info or "").strip()
        if not text:
            return "Error" if issue_kind == "error" else "Warning"

        text = re.sub(r"^\s*(?:\[(?:INFO|OK|WARN|WARNING|ERROR|SKIP)\]\s*)+", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\bSTEP\s*\d{1,3}\b[:\-\s]*", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\b(?:ERROR|WARN(?:ING)?)\b[:\-\s]*", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\s{2,}", " ", text).strip(" -:;,.")

        if not text:
            return "Error" if issue_kind == "error" else "Warning"
        return text


    def _is_benign_warning(info: str) -> bool:
        upper = (info or "").upper()
        if "WARN" not in upper and "WARNING" not in upper:
            return False

        benign_markers = (
            "REBOOT REQUESTED (3010). NORMALIZING EXIT CODE TO 0",
            "DISM REQUESTED A REBOOT",
            "PACKAGE PENDING REBOOT",
            "ACTION LOG NOT FOUND, SKIP MERGE",
            "PATH ALREADY EXISTS AND IS NOT A JUNCTION, KEEP AS-IS",
          "PROGRESS IMAGE UPDATE FAILED",
        )

        return any(marker in upper for marker in benign_markers)


    def _build_issue_details(window, max_issue_lines: int = 300, include_warnings: bool = False) -> str:
      issues = []

      for r in window or []:
        info = (r["info"] or "").strip()
        if not info:
          continue

        level = _log_level(info)
        if level == "error":
          issues.append(info)
          continue

        if include_warnings:
          if level == "warning" and not _is_benign_warning(info):
            issues.append(info)

      if not issues:
        return "No ERROR found in current provisioning run."

      total = len(issues)
      if total > max_issue_lines:
        issues = issues[-max_issue_lines:]
        return f"Showing last {max_issue_lines}/{total} issue lines\n" + "\n".join(issues)

      return "\n".join(issues)


    def _infer_stage(info: str):
        upper = (info or "").upper()

        if _is_end_provision(info):
            return 3
        if "[FINALIZE]" in upper or "FINALIS" in upper:
            return 3
        if _is_running_hook(info):
            return 3

        if (
            "[BASE]" in upper
            or "APPLICATIONS TO INSTALL" in upper
            or "INSTALLING:" in upper
            or "GETAPPS" in upper
        ):
            return 2

        if "DRIVER" in upper or "DETECTED MODEL" in upper or "PACK" in upper:
            return 1

        m = STEP_RE.search(upper)
        if m and m.group(1).isdigit():
            n = int(m.group(1))
            if n >= 10:
                return 3
            if n >= 8:
                return 2
            return 0

        if "START PROVISION" in upper or "TRANSCRIPT" in upper or "EXECUTIONPASS" in upper:
            return 0

        return None


    def _build_pipeline_states(has_start, has_end, has_error, reached, current_stage, error_stage):
        states = ["pending"] * 4

        if has_end and not has_error:
            return ["done", "done", "done", "done"]

        for idx in range(4):
            if idx in reached:
                states[idx] = "done"

        if has_error:
            err_idx = error_stage
            if err_idx is None:
                err_idx = current_stage if current_stage is not None else 0
            err_idx = max(0, min(3, err_idx))
            states[err_idx] = "error"
            for idx in range(err_idx + 1, 4):
                states[idx] = "pending"
            return states

        if has_start:
            cur = current_stage if current_stage is not None else 0
            cur = max(0, min(3, cur))
            states[cur] = "current"

        return states


    def _summarize_runs(rows, fallback_postype: str = ""):
        ustart = "START PROVISION"

        last_start_idx = None
        for idx, r in enumerate(rows):
            if ustart in (r["info"] or "").upper():
                last_start_idx = idx

        window = rows if last_start_idx is None else rows[last_start_idx:]
        has_start = last_start_idx is not None

        has_end = any(_is_end_provision((r["info"] or "")) for r in window)
        has_error = any(_log_level(r["info"] or "") == "error" for r in window)
        has_warn = any(
            _log_level(r["info"] or "") == "warning" and not _is_benign_warning(r["info"] or "")
            for r in window
        )
        has_running_hint = any(_is_running_hook((r["info"] or "")) for r in window)
        issue_details = _build_issue_details(window)

        seen = set()
        warn_step = ""
        error_step = ""
        current_step = ""
        warn_message = ""
        error_message = ""
        warn_count = 0
        error_count = 0

        reached_stages = set()
        error_stage = None

        for r in window:
            info = r["info"] or ""
            level = _log_level(info)

            if level == "warning":
                if not _is_benign_warning(info):
                    warn_count += 1
            elif level == "error":
                error_count += 1

            for m in STEP_RE.findall(info):
                if m.isdigit():
                    n = int(m)
                    if 1 <= n <= 10:
                        current_step = f"{n:03d}"
                        seen.add(current_step)

            if level == "warning" and (not _is_benign_warning(info)) and current_step:
                warn_step = current_step
            if level == "error" and current_step:
                error_step = current_step

            stage = _infer_stage(info)
            if stage is not None:
                reached_stages.add(stage)

        steps_seen = sorted(seen)
        steps_count = len(steps_seen)
        progress = int(round((steps_count / 10.0) * 100)) if steps_count else (100 if has_end else 0)

        start_ts = None
        end_ts = None
        last_ts = None
        last_info = ""
        last_step = ""

        if window:
            last_ts = _parse_dt(window[-1]["datetime"])
            last_info = window[-1]["info"] or ""
            start_ts = _parse_dt(window[0]["datetime"]) if has_start else None

            if has_end:
                for r in window:
                    if _is_end_provision((r["info"] or "")):
                        end_ts = _parse_dt(r["datetime"])
                        break

            for r in reversed(window):
                m = STEP_RE.search(r["info"] or "")
                if m and m.group(1).isdigit():
                    n = int(m.group(1))
                    if 1 <= n <= 10:
                        last_step = f"{n:03d}"
                        break

        for r in reversed(window):
            info = r["info"] or ""
            level = _log_level(info)
            if (not error_message) and (level == "error"):
                error_message = _extract_issue_message(info, "error")
            if (not warn_message) and (level == "warning") and (not _is_benign_warning(info)):
                warn_message = _extract_issue_message(info, "warning")
            if error_message and warn_message:
                break

        for r in reversed(window):
            if _log_level(r["info"] or "") == "error":
                error_stage = _infer_stage(r["info"] or "")
                break

        current_stage = _infer_stage(last_info)

        if has_start:
            reached_stages.add(0)

        if has_end:
            reached_stages.update({0, 1, 2, 3})
            current_stage = 3
        else:
            if current_stage is None and reached_stages:
                current_stage = max(reached_stages)
            if current_stage is not None:
                for idx in range(current_stage + 1):
                    reached_stages.add(idx)

        if has_error and error_stage is None:
            error_stage = current_stage if current_stage is not None else 0

        is_recent = False
        if last_ts:
            try:
                is_recent = (datetime.datetime.now() - last_ts).total_seconds() <= 15 * 60
            except Exception:
                is_recent = False

        if has_error:
            status = "ERROR"
            status_kind = "error"
            color = "bg-danger"
        elif has_warn:
            status = "WARNING"
            status_kind = "warning"
            color = "bg-warning text-dark"
        elif has_start and has_end:
            status = "Completed"
            status_kind = "success"
            color = "bg-success"
        elif (has_start or has_running_hint) and is_recent:
            status = "In progress"
            status_kind = "running"
            color = "bg-info"
        elif has_start:
            status = "Unknown"
            status_kind = "idle"
            color = "bg-secondary"
        elif window:
            status = "Not started"
            status_kind = "idle"
            color = "bg-secondary"
        else:
            status = "No logs"
            status_kind = "idle"
            color = "bg-secondary"

        total_time = None
        if start_ts and (end_ts or last_ts):
            total_time = (end_ts or last_ts) - start_ts
            if total_time.total_seconds() < 0:
                total_time = None

        profile = _detect_profile(window, fallback_postype)

        pipeline_states = _build_pipeline_states(
            has_start=has_start,
            has_end=has_end,
            has_error=has_error,
            reached=reached_stages,
            current_stage=current_stage,
            error_stage=error_stage,
        )

        step_number = 0
        if has_end:
            step_number = 10
        elif last_step and last_step.isdigit():
            step_number = max(0, min(10, int(last_step)))
        elif steps_seen:
            try:
                step_number = max(0, min(10, int(steps_seen[-1])))
            except Exception:
                step_number = 0

        step_progress_pct = step_number * 10
        list_progress_pct = 100 if has_error else step_progress_pct
        is_live = bool((has_start or has_running_hint) and (not has_end) and (not has_error) and is_recent)

        return {
            "progress": 100 if has_end and not has_error else progress,
            "steps_count": steps_count,
            "steps_seen": steps_seen,
            "last_step": last_step,
            "warn_step": warn_step,
            "error_step": error_step,
            "warn_message": warn_message,
            "error_message": error_message,
            "issue_details": issue_details,
            "warn_count": warn_count,
            "error_count": error_count,
            "has_start": has_start,
            "has_end": has_end,
            "has_error": has_error,
            "has_warn": has_warn,
            "start_ts": start_ts,
            "end_ts": end_ts,
            "last_ts": last_ts,
            "last_info": last_info,
            "total_time": total_time,
            "status": status,
            "status_kind": status_kind,
            "status_label": status,
            "color": color,
            "profile": profile,
            "current_stage": current_stage,
            "error_stage": error_stage,
            "pipeline_states": pipeline_states,
            "step_number": step_number,
            "step_progress_pct": step_progress_pct,
            "list_progress_pct": list_progress_pct,
            "is_live": is_live,
        }


    def _last_run_rows(rows):
        ustart = "START PROVISION"
        last_start_idx = None

        for idx, r in enumerate(rows or []):
            if ustart in (r["info"] or "").upper():
                last_start_idx = idx

        if last_start_idx is None:
            return list(rows or [])
        return list((rows or [])[last_start_idx:])


    def _dedupe_rows(rows):
        deduped = []
        seen = set()

        for row in rows or []:
            key = ((row["datetime"] or ""), (row["info"] or ""))
            if key in seen:
                continue
            seen.add(key)
            deduped.append(row)

        return deduped


    def _collect_progress_by_device():
        logs_conn = get_logs_db()
        rows = logs_conn.execute(
            """
            SELECT macaddress, id, datetime, info
            FROM deployment_info
            ORDER BY macaddress ASC, id ASC;
            """
        ).fetchall()

        conn = get_db()
        comp_rows = conn.execute(
            "SELECT macaddress, computername, postype FROM newcomputer;"
        ).fetchall()

        logs_conn.close()
        conn.close()

        names = {}
        postypes = {}
        for r in comp_rows:
            mac = (r["macaddress"] or "").strip()
            if not mac:
                continue
            names[mac] = (r["computername"] or "").strip()
            postypes[mac] = _clean_profile(r["postype"] or "")

        devices = {}
        for r in rows:
            mac = r["macaddress"]
            devices.setdefault(mac, []).append(r)

        summary = {}
        for mac, logs in devices.items():
            s = _summarize_runs(logs, postypes.get(mac, ""))
            display = names.get(mac) or mac
            s.update({"display": display, "serial": mac})
            summary[mac] = s

        return summary


    def _summary_to_json(s):
        def dt2s(dt):
            return dt.strftime("%Y-%m-%d %H:%M:%S") if dt else None

        return {
            "progress": s["progress"],
            "steps_count": s["steps_count"],
            "steps_seen": s["steps_seen"],
            "has_start": s["has_start"],
            "has_end": s["has_end"],
            "has_error": s["has_error"],
            "has_warn": s["has_warn"],
            "start_ts": dt2s(s["start_ts"]),
            "end_ts": dt2s(s["end_ts"]),
            "last_ts": dt2s(s["last_ts"]),
            "total_time": _format_td(s["total_time"]) if s["total_time"] else None,
            "status": s["status"],
            "status_label": s["status_label"],
            "status_kind": s["status_kind"],
            "color": s["color"],
            "profile": s["profile"],
            "last_step": s["last_step"],
            "warn_message": s["warn_message"],
            "error_message": s["error_message"],
            "issue_details": s["issue_details"],
            "warn_count": s["warn_count"],
            "error_count": s["error_count"],
            "step_number": s["step_number"],
            "step_progress_pct": s["step_progress_pct"],
            "list_progress_pct": s["list_progress_pct"],
            "is_live": s["is_live"],
            "current_stage": s["current_stage"],
            "error_stage": s["error_stage"],
            "pipeline_states": s["pipeline_states"],
            "last_info": s["last_info"],
        }


    @bp.route("/progress")
    def progress_page():
        data = _collect_progress_by_device()
        role = (session.get("role") or "").strip().lower()
        can_clear = role in ("admin", "operator")

        def ts_desc(item):
            _mac, s = item
            ts = s.get("last_ts")
            return -(ts.timestamp() if ts else 0)

        session_key = "progress_row_order"
        existing_order = session.get(session_key)
        data_items = list(data.items())

        if not isinstance(existing_order, list) or not existing_order:
            # First display: newest activity first.
            items = sorted(data_items, key=ts_desc)
            session[session_key] = [mac for mac, _s in items]
            session.modified = True
        else:
            by_mac = {mac: s for mac, s in data_items}
            items = []
            seen = set()

            # Keep previous visual order during refreshes (no yoyo).
            for mac in existing_order:
                s = by_mac.get(mac)
                if s is None:
                    continue
                items.append((mac, s))
                seen.add(mac)

            # New devices are appended (newest first among newcomers).
            newcomers = [(mac, s) for mac, s in data_items if mac not in seen]
            newcomers.sort(key=ts_desc)
            items.extend(newcomers)

            new_order = [mac for mac, _s in items]
            if new_order != existing_order:
                session[session_key] = new_order
                session.modified = True

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Progress</title>
      <meta http-equiv="refresh" content="30">
      <script src="https://cdn.tailwindcss.com"></script>
    __HEAD_ASSETS__
      <style>
        :root{
          --bg:#f4f7f6;
          --panel:#ffffff;
          --border:#d8e1eb;
          --text:#243447;
          --heading:#17324f;
          --muted:#6b7280;
          --link:#1d6fd1;
          --table-cols:25fr 50fr 15fr 10fr;
        }

        html,body{height:100%}
        body{background:#f8fafc; color:#0f172a}
        a, a:hover{color:var(--link)}

        .refresh-indicator{
          display:inline-flex;
          align-items:center;
          gap:.45rem;
          color:#5f7388;
          font-size:.8rem;
          font-weight:600;
          white-space:nowrap;
        }
        .refresh-ring{
          width:16px;
          height:16px;
          border-radius:999px;
          border:2px solid rgba(59,130,246,.18);
          border-top-color:#3b82f6;
          animation:refresh-spin 30s linear infinite;
        }
        @keyframes refresh-spin{
          from{transform:rotate(0deg)}
          to{transform:rotate(360deg)}
        }

        .chip{
          display:inline-flex;
          align-items:center;
          gap:.6rem;
          height:48px;
          padding:0 .82rem;
          border-radius:12px;
          border:1px solid #cfd9e4;
          background:#fff;
          color:#1f3b59;
          text-decoration:none;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
          transition:.15s ease;
          white-space:nowrap;
        }
        .chip:hover{
          transform:translateY(-1px);
          border-color:#9fb3c8;
          box-shadow:0 6px 14px rgba(0,0,0,.1);
          text-decoration:none;
        }
        .chip-nav{background:#fff}

        .modicon{
          width:32px;
          height:32px;
          border-radius:10px;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          box-shadow:inset 0 0 0 1px rgba(0,0,0,.14), 0 2px 8px rgba(0,0,0,.12);
        }
        .modicon svg{width:18px; height:18px}
        .modicon svg *{stroke:#fff; stroke-width:2; fill:none; stroke-linecap:round; stroke-linejoin:round}
        .mi-home{background:#3fa7ff}

        .searchwrap{
          position:relative;
          min-width:280px;
          width:100%;
          max-width:400px;
        }
        .searchbox{
          width:100%;
          height:44px;
          padding:0 .85rem 0 2.35rem;
          border-radius:12px;
          border:1px solid #cbd5e1;
          background:#fff;
          color:#334155;
          outline:0;
          box-shadow:0 1px 2px rgba(15,23,42,.04);
        }
        .searchbox::placeholder{color:#8da0b5}
        .searchwrap svg{
          position:absolute;
          left:.75rem;
          top:50%;
          transform:translateY(-50%);
          width:18px;
          height:18px;
          opacity:.75;
          color:#8da0b5;
        }

        .progress-table{overflow-x:auto}
        .table-grid{min-width:1080px}

        .table-head,
        .table-row{
          display:grid !important;
          grid-template-columns:var(--table-cols);
          align-items:center;
          column-gap:.8rem;
        }

        .table-head{
          background:#f8f9fa;
          font-family:"Segoe UI",system-ui,-apple-system,BlinkMacSystemFont,sans-serif;
          font-size:.82rem;
          letter-spacing:0;
          text-transform:none;
          font-weight:800;
          color:#2e4358;
          padding:.72rem 1.5rem;
          border-bottom:1px solid #dce5ee;
        }

        .table-body{display:flex; flex-direction:column}
        .table-row{
          border-bottom:1px solid #e8eef4;
          padding:.85rem 1.5rem;
          cursor:pointer;
          transition:background .15s ease;
          min-height:76px;
        }
        .table-row:hover{background:#f6f9fc}
        .table-row:last-of-type{border-bottom:none}

        .cell-device{min-width:0}
        .device-id{
          font-size:1rem;
          font-weight:800;
          color:#21364b;
          line-height:1.15;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
        }
        .profile-row{margin-top:.18rem}
        .profile-pill{
          letter-spacing:.02em;
        }
        .cell-status{min-width:0}
        .progress-track{
          width:100%;
          height:10px;
          border-radius:999px;
          background:#eef2f7;
          overflow:hidden;
          border:1px solid #dde6ef;
        }
        .progress-fill{
          height:100%;
          border-radius:999px;
          transition:width .35s ease;
          background:#94a3b8;
        }
        .progress-fill.st-success{background:#22c55e}
        .progress-fill.st-running{background:linear-gradient(90deg,#2563eb,#3b82f6)}
        .progress-fill.st-warning{background:#f59e0b}
        .progress-fill.st-idle{background:#94a3b8}
        .progress-fill.st-error{background:#dc2626}
        .progress-fill.st-running.is-live{
          background-image:linear-gradient(
            45deg,
            rgba(255,255,255,.24) 25%,
            transparent 25%,
            transparent 50%,
            rgba(255,255,255,.24) 50%,
            rgba(255,255,255,.24) 75%,
            transparent 75%,
            transparent
          );
          background-size:1rem 1rem;
          animation:progress-live 1s linear infinite;
        }
        @keyframes progress-live{
          from{background-position:0 0}
          to{background-position:1rem 0}
        }

        .status-text{
          margin-top:.26rem;
          font-size:.8rem;
          font-weight:700;
          color:#4b5563;
          white-space:nowrap;
          overflow:hidden;
          text-overflow:ellipsis;
        }
        .status-error-box{
          margin-top:.34rem;
          display:flex;
          align-items:center;
          gap:.45rem;
          padding:.38rem .55rem;
          border-radius:10px;
          border:1px solid rgba(220,38,38,.16);
          background:rgba(220,38,38,.08);
          min-width:0;
        }
        .status-error-box .status-text{
          margin-top:0;
          color:#b91c1c;
          font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
          font-size:.76rem;
          font-weight:700;
        }
        .status-detail-icon{
          width:24px;
          height:24px;
          border-radius:8px;
          border:1px solid rgba(220,38,38,.18);
          background:#fff;
          color:#b91c1c;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          flex:0 0 auto;
        }
        .status-detail-icon svg{
          width:13px;
          height:13px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .status-warning{color:#b45309}
        .status-error{color:#b91c1c}
        .status-running{color:#1d4ed8}
        .status-success{color:#15803d}
        .progress-status-warning{color:#b45309}
        .progress-status-error{color:#b91c1c}
        .progress-status-running{color:#1d4ed8}
        .progress-status-success{color:#15803d}
        .progress-status-idle{color:#64748b}

        .cell-action,
        .cell-start{
          display:flex;
          align-items:center;
          justify-content:flex-start;
          min-height:44px;
        }

        .cell-action{
          gap:0;
          justify-content:flex-end;
        }
        .cell-action form{
          margin:0;
        }
        .progress-action-btn{
          min-width:92px;
          height:34px;
          margin-left:4px;
          margin-right:4px;
          border-radius:10px;
          border:1px solid #d8e3ee;
          background:#fff;
          color:#5b7088;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          gap:.35rem;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
          text-decoration:none;
          font-size:.78rem;
          font-weight:800;
          line-height:1;
        }
        .progress-action-btn:hover{
          transform:translateY(-1px);
          box-shadow:0 6px 14px rgba(0,0,0,.1);
          text-decoration:none;
        }
        .progress-action-view{
          border-color:#bcd1e5;
          background:#eff6fc;
          color:#0f5d92;
        }
        .progress-action-view:hover{
          border-color:#9ebfdd;
          background:#e2f1fb;
          color:#0b4e7d;
        }
        .progress-delete-btn{
          width:36px;
          height:36px;
          border-radius:10px;
          border:1px solid #f1c0c5;
          background:#fff0f1;
          color:#b91c1c;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
        }
        .progress-delete-btn svg{
          width:16px;
          height:16px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .progress-delete-btn:hover{
          border-color:#e9a8af;
          background:#ffe3e6;
          color:#991b1b;
          transform:translateY(-1px);
          box-shadow:0 6px 14px rgba(0,0,0,.1);
        }
        .icon-btn-view{
          width:36px;
          height:36px;
          border-radius:10px;
          border:1px solid #d8e3ee;
          background:#fff;
          color:#4d6882;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
        }
        .icon-btn-view svg{
          width:16px;
          height:16px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .icon-btn-view:hover{
          border-color:#bcd1e5;
          background:#eff6fc;
          color:#0f5d92;
          transform:translateY(-1px);
          box-shadow:0 6px 14px rgba(0,0,0,.1);
        }

        .start-time{
          color:#334155;
          font-weight:700;
          font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
          font-size:.88rem;
          font-variant-numeric:tabular-nums;
          letter-spacing:.03em;
          white-space:nowrap;
        }

        .no-match{
          padding:.85rem;
          text-align:center;
          color:#6b7280;
          font-weight:600;
        }

        @media (max-width: 1150px){
          .searchwrap{max-width:none}
        }
      </style>
    </head>
    <body class="min-h-screen bg-slate-50 text-slate-900">
      <div class="container-fluid">
        <main class="mx-auto max-w-[1800px] px-8 py-8">
          <div class="mb-6 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">Administration</p>
              <h1 class="mt-2 text-3xl font-extrabold tracking-tight text-slate-950">Progress</h1>
              <div class="mt-2 refresh-indicator"><span class="refresh-ring" aria-hidden="true"></span><span>Refresh every 30s</span></div>
            </div>

            <form class="searchwrap" method="get" action="{{ url_for('progress.progress_page') }}" role="search" onsubmit="return false;">
              <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7" stroke="currentColor" fill="none" stroke-width="2"/><path d="M20 20l-3.2-3.2" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
              <input id="searchBox" name="q" class="searchbox" type="search" placeholder="Search device or profile" value="" autocomplete="off">
            </form>
          </div>

          <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
            <div class="max-h-[calc(100vh-190px)] overflow-auto">
          {% if items|length == 0 %}
            <div class="p-3 text-muted">No devices with logs.</div>
          {% else %}
            <div class="progress-table">
              <div class="table-grid">
                <div class="table-head">
                  <div>Device &amp; Profile</div>
                  <div>Status &amp; Error</div>
                  <div>Start time</div>
                  <div></div>
                </div>

                <div id="jobList" class="table-body">
                  {% for mac, s in items %}
                  {% set profile_norm = (s.profile or '')|upper %}
                  <article class="table-row data-row"
                           data-device="{{ ((s.display or s.serial) ~ ' ' ~ s.serial ~ ' ' ~ (s.profile or '') ~ ' ' ~ (s.last_info or '') ~ ' ' ~ (s.error_message or '') ~ ' ' ~ (s.warn_message or ''))|lower }}"
                           data-href="{{ url_for('progress.progress_detail', mac=mac) }}"
                           tabindex="0"
                           role="link"
                           aria-label="Open {{ s.display or s.serial }}">

                    <div class="cell-device">
                      <div class="device-id">{{ s.display or s.serial }}</div>
                      <div class="profile-row">
                        <span class="profile-pill status-badge status-info">
                          {{ s.profile or 'BASE' }}
                        </span>
                      </div>
                    </div>

                    <div class="cell-status">
                      <div class="progress-track" aria-label="Progress">
                        <div class="progress-fill st-{{ s.status_kind }}{% if s.status_kind == 'running' and s.is_live %} is-live{% endif %}"
                             style="width: {{ s.list_progress_pct }}%;"></div>
                      </div>
                      {% if s.has_error %}
                      <div class="status-error-box">
                        <span class="status-detail-icon" aria-hidden="true">
                          <svg viewBox="0 0 24 24"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6-10-6-10-6z"></path><circle cx="12" cy="12" r="2.5"></circle></svg>
                        </span>
                        <div class="status-text progress-status-error">{{ s.error_message or s.last_info or 'Error' }}</div>
                      </div>
                      {% elif s.has_warn %}
                      <div class="status-text progress-status-warning">Step {{ s.step_number }}/10 - {{ s.warn_message or 'Warning' }}</div>
                      {% else %}
                      <div class="status-text progress-status-{{ s.status_kind }}">Step {{ s.step_number }}/10{% if s.status_label %} - {{ s.status_label }}{% endif %}</div>
                      {% endif %}
                    </div>

                    <div class="cell-start">
                      <div class="start-time">{% if s.start_ts %}{{ s.start_ts.strftime("%Y-%m-%d %H:%M") }}{% else %}-{% endif %}</div>
                    </div>

                    <div class="cell-action">
                      {% if can_clear %}
                      <form method="post" action="{{ url_for('progress.progress_clear_device', mac=mac) }}" onsubmit="event.stopPropagation(); return confirm('Clear progress for {{ s.display or s.serial }}?');">
                        <button class="progress-delete-btn" type="submit" title="Delete {{ s.display or s.serial }}" aria-label="Delete {{ s.display or s.serial }}">
                          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6l1-2h6l1 2"></path><path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path><path d="M14 10v6"></path></svg>
                        </button>
                      </form>
                      {% endif %}
                    </div>

                  </article>
                  {% endfor %}
                </div>

                <div id="noMatch" class="no-match" style="display:none;">No matching devices</div>
              </div>
            </div>
          {% endif %}
            </div>
          </section>
        </main>
      </div>

      <script>
      (function(){
        const input   = document.getElementById('searchBox');
        if (!input) return;

        const rows    = Array.from(document.querySelectorAll('.data-row'));
        const noMatch = document.getElementById('noMatch');
        const STORAGE_KEY = 'ws_progress_device_filter';

        for (const row of rows){
          row.addEventListener('click', () => {
            const href = row.dataset.href;
            if (href) window.location.href = href;
          });
          row.addEventListener('keydown', (ev) => {
            if (ev.key === 'Enter' || ev.key === ' ') {
              ev.preventDefault();
              const href = row.dataset.href;
              if (href) window.location.href = href;
            }
          });
        }

        for (const control of document.querySelectorAll('.cell-action form, .cell-action button')){
          control.addEventListener('click', (ev) => {
            ev.stopPropagation();
          });
          control.addEventListener('keydown', (ev) => {
            ev.stopPropagation();
          });
        }

        function doFilter(){
          const raw = input.value || '';
          const q = raw.trim().toLowerCase();
          let shown = 0;

          for (const row of rows){
            const hay = (row.dataset.device || '').toLowerCase();
            const ok  = !q || hay.indexOf(q) !== -1;
            row.style.display = ok ? '' : 'none';
            if (ok) shown++;
          }

          if (noMatch) noMatch.style.display = shown ? 'none' : '';

          try {
            window.localStorage.setItem(STORAGE_KEY, raw);
          } catch(e) {
          }
        }

        let t;
        input.addEventListener('input', () => {
          clearTimeout(t);
          t = setTimeout(doFilter, 80);
        });

        try {
          const saved = window.localStorage.getItem(STORAGE_KEY);
          if (saved !== null) {
            input.value = saved;
          }
        } catch(e) {
        }

        doFilter();
      })();
      </script>
    </body>
    </html>
    """
        return render_inline(tmpl, items=items, format_td=_format_td, can_clear=can_clear)


    @bp.route("/progress/<mac>/clear", methods=["POST"])
    @require_roles("admin", "operator")
    def progress_clear_device(mac):
        mac_norm = normalize_id(mac)
        conn = get_logs_db()
        conn.execute(
            """
            DELETE FROM deployment_info
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?;
            """,
            (mac_norm,),
        )
        conn.commit()
        conn.close()
        return redirect(url_for("progress.progress_page"))


    @bp.route("/progress/<mac>")
    def progress_detail(mac):
        mac_norm = normalize_id(mac)
        logs_conn = get_logs_db()
        conn = get_db()

        rows = logs_conn.execute(
            """
            SELECT id, datetime, info
            FROM deployment_info
            WHERE macaddress = ?
            ORDER BY id ASC;
            """,
            (mac_norm,),
        ).fetchall()

        comp_row = conn.execute(
            """
            SELECT computername, postype
            FROM newcomputer
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?
            LIMIT 1;
            """,
            (mac_norm,),
        ).fetchone()

        logs_conn.close()
        conn.close()

        compname = (comp_row["computername"] or "").strip() if comp_row else ""
        postype = (comp_row["postype"] or "").strip() if comp_row else ""
        logs_href = _logs_href_for_computer(compname)

        summary = _summarize_runs(rows, postype)

        rows_view = []
        last_log_id = 0
        last_run_rows = _last_run_rows(rows)
        for r in last_run_rows:
            rid = int(r["id"])
            if rid > last_log_id:
                last_log_id = rid

        for r in _dedupe_rows(last_run_rows):
            rid = int(r["id"])
            tag, body = _split_log_tag(r["info"] or "")
            rows_view.append(
                {
                    "id": rid,
                    "datetime": r["datetime"],
                    "info": r["info"] or "",
                    "level": _log_level(r["info"] or ""),
                    "tag": tag,
                    "body": body,
                }
            )

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Progress - {{ mac }}</title>
    __HEAD_ASSETS__
      <style>
        :root{
          --bg:#f4f7fb;
          --panel:#ffffff;
          --panel-2:#ffffff;
          --border:#c5d3e2;
          --text:#102a43;
          --heading:#0f2942;
          --muted:#4f6782;
          --link:#145ea8;
          --step-pending:#3a4860;
          --step-done:#37d67a;
          --step-current:#43a2ff;
          --step-error:#ff6b6b;
          --term-bg:#1e1e1e;
          --term-fg:#d4d4d4;
          --term-info:#45d6ff;
          --term-ok:#66e29a;
          --term-warn:#ffbb55;
          --term-error:#ff5f56;
        }

        body{background:var(--bg); color:var(--text)}
        a, a:hover{color:var(--link)}

        .header-main{
          display:flex;
          justify-content:space-between;
          align-items:flex-end;
          gap:1rem;
          flex-wrap:wrap;
        }
        .board{
          border:1px solid var(--border);
          border-radius:16px;
          background:var(--panel);
          box-shadow:0 10px 24px rgba(16,42,67,.12);
          padding:1rem;
          display:flex;
          flex-direction:column;
          min-height:calc(100vh - 180px);
        }

        .page-title{color:var(--heading)!important; margin:0}
        .machine-name{
          font-family:"JetBrains Mono","Fira Code",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
          color:#17324f;
          font-size:.92em;
          font-weight:800;
        }

        .summary-grid{
          display:grid;
          grid-template-columns:repeat(4, minmax(0, 1fr));
          gap:.8rem;
          margin-top:.9rem;
        }

        .summary-block{
          background:var(--panel-2);
          border:1px solid var(--border);
          border-radius:14px;
          padding:.8rem .9rem;
          min-height:92px;
          box-shadow:0 4px 12px rgba(16,42,67,.05);
        }

        .summary-label{
          color:var(--muted);
          font-size:.74rem;
          letter-spacing:.03em;
          text-transform:uppercase;
          margin-bottom:.35rem;
        }

        .summary-value{
          color:#102a43;
          font-weight:700;
          font-size:1rem;
          word-break:break-word;
        }

        .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:.9rem}

        .status-badge{
          display:inline-flex;
          align-items:center;
          padding:.25rem .62rem;
          border-radius:999px;
          border:1px solid transparent;
          font-size:.78rem;
          font-weight:700;
          letter-spacing:.02em;
        }
        .status-large{font-size:.86rem; padding:.35rem .8rem}
        .status-badge.st-success{color:#146c43; background:rgba(55,214,122,.16); border-color:rgba(20,108,67,.28)}
        .status-badge.st-running{color:#0f5cb0; background:rgba(67,162,255,.16); border-color:rgba(15,92,176,.3)}
        .status-badge.st-warning{color:#8d5d00; background:rgba(255,176,32,.2); border-color:rgba(141,93,0,.35)}
        .status-badge.st-error{color:#d12626; background:rgba(220,38,38,.1); border-color:rgba(220,38,38,.18)}
        .status-badge.st-idle{color:#4f6782; background:rgba(148,163,184,.2); border-color:rgba(79,103,130,.3)}

        .linear-progress{
          margin-top:1rem;
          border:1px solid var(--border);
          border-radius:14px;
          background:var(--panel-2);
          padding:.85rem .9rem;
        }

        .issue-card{
          margin-top:1rem;
          border:1px solid #f0c7c7;
          border-radius:14px;
          background:#fff6f6;
          padding:.85rem .9rem;
          box-shadow:0 4px 12px rgba(16,42,67,.05);
        }

        .issue-card.is-clean{
          border-color:var(--border);
          background:var(--panel-2);
        }

        .issue-title{
          color:#8f1d1d;
          font-size:.84rem;
          font-weight:800;
          letter-spacing:.03em;
          text-transform:uppercase;
          margin-bottom:.55rem;
        }

        .issue-card.is-clean .issue-title{
          color:var(--muted);
        }

        .issue-box{
          width:100%;
          min-height:132px;
          border:1px solid #e6b8b8;
          border-radius:10px;
          background:#fffdfd;
          color:#5f1616;
          font-family:"JetBrains Mono","Fira Code",Consolas,"Courier New",monospace;
          font-size:.82rem;
          line-height:1.45;
          padding:.7rem .8rem;
          resize:vertical;
        }

        .issue-card.is-clean .issue-box{
          border-color:var(--border);
          background:#fbfdff;
          color:#334e68;
        }

        .linear-progress-label{
          color:#0f2942;
          font-size:.9rem;
          font-weight:600;
          margin-bottom:.55rem;
        }

        .linear-track{
          width:100%;
          height:22px;
          border-radius:999px;
          overflow:hidden;
          background:#0d1424;
          border:1px solid rgba(255,255,255,.12);
          box-shadow:inset 0 1px 2px rgba(0,0,0,.45);
        }

        .linear-fill{
          height:100%;
          min-width:0;
          width:0%;
          border-radius:999px;
          display:flex;
          align-items:center;
          justify-content:flex-end;
          padding-right:.45rem;
          color:#f1f7ff;
          font-size:.72rem;
          font-weight:700;
          transition:width .45s ease;
          background:#2f89ff;
        }

        .linear-fill.state-success{background:#2baa63}
        .linear-fill.state-error{
          background:#d64545;
          justify-content:center;
          padding-right:0;
        }
        .linear-fill.state-idle{background:#5c6d86}
        .linear-error-text{
          display:inline-flex;
          align-items:center;
          gap:.3rem;
        }

        .linear-fill.is-live{
          background-image:linear-gradient(
            45deg,
            rgba(255,255,255,.18) 25%,
            transparent 25%,
            transparent 50%,
            rgba(255,255,255,.18) 50%,
            rgba(255,255,255,.18) 75%,
            transparent 75%,
            transparent
          );
          background-size:1.2rem 1.2rem;
          animation:stripe-move .85s linear infinite, live-pulse 1.7s ease-in-out infinite;
        }

        @keyframes stripe-move {
          from{background-position:0 0}
          to{background-position:1.2rem 0}
        }

        @keyframes live-pulse {
          0%{filter:brightness(1)}
          50%{filter:brightness(1.18)}
          100%{filter:brightness(1)}
        }

        .live-hourglass{
          display:inline-block;
          margin-right:.25rem;
          animation:live-hourglass-spin 1.1s linear infinite;
          transform-origin:center;
        }

        @keyframes live-hourglass-spin {
          from{transform:rotate(0deg)}
          to{transform:rotate(360deg)}
        }

        .terminal-card{
          margin-top:1rem;
          border:1px solid var(--border);
          border-radius:14px;
          overflow:hidden;
          background:#151b27;
          display:flex;
          flex-direction:column;
          flex:1 1 auto;
          min-height:420px;
        }

        .terminal-head{
          display:flex;
          justify-content:space-between;
          align-items:center;
          gap:.8rem;
          padding:.7rem .9rem;
          border-bottom:1px solid var(--border);
          background:#111827;
          color:#d8e7ff;
          font-weight:600;
        }

        .term-title{font-size:.9rem; letter-spacing:.02em}
        .terminal-tools{
          display:flex;
          align-items:center;
          gap:.6rem;
          flex-wrap:wrap;
          margin-left:auto;
        }
        .terminal-search{
          width:320px;
          max-width:65vw;
          padding:.38rem .6rem;
          border-radius:9px;
          border:1px solid #2f3d53;
          background:#0f1723;
          color:#d8e7ff;
          outline:0;
          font-size:.83rem;
        }
        .terminal-search::placeholder{color:#8ea5c4}
        .terminal-search:focus{
          border-color:#3b82f6;
          box-shadow:0 0 0 .14rem rgba(59,130,246,.24);
        }
        .terminal-icon-btn{
          width:34px;
          height:34px;
          border-radius:9px;
          border:1px solid #2f3d53;
          background:#0f1723;
          color:#d8e7ff;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.22);
        }
        .terminal-icon-btn svg{
          width:16px;
          height:16px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .terminal-icon-btn:hover{
          border-color:#4f6d90;
          background:#142133;
          color:#ffffff;
          transform:translateY(-1px);
        }
        .terminal-no-match{
          display:none;
          padding:.5rem .9rem;
          font-size:.82rem;
          color:#9fb3ce;
          border-top:1px solid var(--border);
          background:#131c29;
        }

        .switch{
          display:inline-flex;
          align-items:center;
          gap:.45rem;
          color:#b4c5dc;
          font-size:.82rem;
          user-select:none;
        }

        .switch input{
          accent-color:#43a2ff;
          width:15px;
          height:15px;
        }

        .terminal{
          flex:1 1 auto;
          height:auto;
          min-height:420px;
          overflow:auto;
          background:var(--term-bg);
          color:var(--term-fg);
          font-family:"JetBrains Mono","Fira Code",Consolas,"Courier New",monospace;
          font-size:.85rem;
          line-height:1.45;
          padding:.75rem .9rem;
        }

        .term-line{
          display:flex;
          gap:.75rem;
          white-space:pre-wrap;
          word-break:break-word;
          padding:.12rem .42rem;
          border-radius:8px;
        }
        .term-line.is-halt-line{
          background:rgba(255,95,86,.12);
          box-shadow:inset 3px 0 0 rgba(255,95,86,.75);
        }

        .term-time{
          flex:0 0 auto;
          color:#8f98a7;
          min-width:19ch;
          font-variant-numeric:tabular-nums;
        }

        .term-msg{
          flex:1 1 auto;
          color:var(--term-fg);
          display:flex;
          align-items:flex-start;
          gap:.5rem;
          min-width:0;
        }
        .term-tag{
          display:inline-flex;
          align-items:center;
          padding:.05rem .36rem;
          border-radius:999px;
          font-size:.72rem;
          font-weight:800;
          letter-spacing:.02em;
          border:1px solid transparent;
          flex:0 0 auto;
        }
        .tag-info{color:#7ddfff; background:rgba(69,214,255,.12); border-color:rgba(69,214,255,.24)}
        .tag-ok{color:#7df0ad; background:rgba(102,226,154,.12); border-color:rgba(102,226,154,.24)}
        .tag-warning{color:#ffc36b; background:rgba(255,187,85,.12); border-color:rgba(255,187,85,.24)}
        .tag-error{color:#ff7b72; background:rgba(255,95,86,.14); border-color:rgba(255,95,86,.26)}
        .term-text{min-width:0; color:var(--term-fg)}
        .lvl-info .term-text{color:var(--term-info)}
        .lvl-ok .term-text{color:var(--term-ok)}
        .lvl-warning .term-text{color:var(--term-warn)}
        .lvl-error .term-text{color:var(--term-error)}

        @media (max-width: 1024px){
          .summary-grid{grid-template-columns:repeat(2, minmax(0, 1fr));}
        }

        @media (max-width: 620px){
          .summary-grid{grid-template-columns:1fr;}
          .terminal{height:340px}
        }
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <div class="header-main mb-3">
          <h1 class="page-title mb-0">
            Device
            {% if compname %}
              <span id="machineTitle" class="machine-name" title="{{ mac }}">{{ compname }}</span>
            {% else %}
              <span id="machineTitle" class="machine-name">{{ mac }}</span>
            {% endif %}
          </h1>
        </div>

        <section class="board">
          <div class="summary-grid">
            <div class="summary-block">
              <div class="summary-label">Statut</div>
              <div class="summary-value">
                <span id="statusBadge" class="status-badge status-large st-{{ summary.status_kind }}">{{ summary.status_label }}</span>
              </div>
            </div>

            <div class="summary-block">
              <div class="summary-label">Profil deploye</div>
              <div id="profileValue" class="summary-value">{{ summary.profile }}</div>
            </div>

            <div class="summary-block">
              <div class="summary-label">Heure de debut</div>
              <div id="startValue" class="summary-value mono">{% if summary.start_ts %}{{ summary.start_ts.strftime("%Y-%m-%d %H:%M") }}{% else %}-{% endif %}</div>
            </div>

            <div class="summary-block">
              <div class="summary-label">Duree totale</div>
              <div id="durationValue" class="summary-value mono">{% if summary.total_time %}{{ format_td(summary.total_time) }}{% else %}-{% endif %}</div>
            </div>
          </div>

          <div class="linear-progress">
            <div id="stepProgressLabel" class="linear-progress-label">
              {% if summary.has_error %}
                Deployment failed
              {% elif summary.has_end %}
                Provisioning completed: Step {{ summary.step_number }} / 10
              {% else %}
                Provisioning in progress: Step {{ summary.step_number }} / 10
              {% endif %}
            </div>
            <div class="linear-track">
              <div
                id="stepProgressBar"
                class="linear-fill{% if summary.has_error %} state-error{% elif summary.has_end %} state-success{% elif not summary.has_start %} state-idle{% endif %}{% if summary.is_live %} is-live{% endif %}"
                style="width: {% if summary.has_error %}100{% else %}{{ summary.step_progress_pct }}{% endif %}%;"
              >{% if summary.has_error %}<span class="linear-error-text">&#9888; {{ summary.error_count }} erreur{% if summary.error_count != 1 %}s{% endif %} | {{ summary.warn_count }} warning{% if summary.warn_count != 1 %}s{% endif %}</span>{% else %}{{ summary.step_progress_pct }}%{% endif %}</div>
            </div>
          </div>

          <div class="terminal-card">
            <div class="terminal-head">
              <span class="term-title">Live Terminal</span>
            </div>

            <div id="terminal" class="terminal" role="log" aria-live="polite" aria-label="Live logs">
              {% if rows|length == 0 %}
                <div id="terminalEmpty" class="term-line lvl-info">
                  <span class="term-time">-</span>
                  <span class="term-msg">No logs</span>
                </div>
              {% else %}
                {% for r in rows|reverse %}
                  <div class="term-line lvl-{{ r.level }}{% if r.level == 'error' %} is-halt-line{% endif %}" data-log-id="{{ r.id }}" data-line="log" data-search="{{ ((r.datetime or '') ~ ' ' ~ (r.info or ''))|lower }}">
                    <span class="term-time">{{ r.datetime }}</span>
                    <span class="term-msg">
                      {% if r.tag %}<span class="term-tag tag-{% if r.level == 'warning' %}warning{% else %}{{ r.level }}{% endif %}">{{ r.tag }}</span>{% endif %}
                      <span class="term-text">{{ r.body if r.tag else r.info }}</span>
                    </span>
                  </div>
                {% endfor %}
              {% endif %}
            </div>
            <div id="terminalNoMatch" class="terminal-no-match">No matching logs</div>
          </div>
        </section>

      </div>

      <script>
      (function(){
        const terminal = document.getElementById('terminal');
        const terminalEmpty = document.getElementById('terminalEmpty');
        const terminalNoMatch = document.getElementById('terminalNoMatch');
        const statusBadge = document.getElementById('statusBadge');
        const profileValue = document.getElementById('profileValue');
        const startValue = document.getElementById('startValue');
        const durationValue = document.getElementById('durationValue');
        const stepProgressLabel = document.getElementById('stepProgressLabel');
        const stepProgressBar = document.getElementById('stepProgressBar');

        const maxLines = 1800;
        const trimTo = 1400;

        let lastId = {{ last_log_id }};
        let pollInFlight = false;
        const renderedIds = new Set();
        const liveUrl = "{{ url_for('progress.progress_device_live_json', mac=mac) }}";

        function parseDbDateTime(value){
          if (!value) return null;
          const dt = new Date(String(value).replace(' ', 'T'));
          if (isNaN(dt.getTime())) return null;
          return dt;
        }

        function formatElapsed(seconds){
          const s = Math.max(0, Number(seconds) || 0);
          const h = Math.floor(s / 3600);
          const m = Math.floor((s % 3600) / 60);
          const sec = s % 60;
          return String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(sec).padStart(2, '0');
        }

        function formatMinuteStamp(value){
          const dt = parseDbDateTime(value);
          if (!dt) return value || '-';
          const y = dt.getFullYear();
          const mo = String(dt.getMonth() + 1).padStart(2, '0');
          const d = String(dt.getDate()).padStart(2, '0');
          const h = String(dt.getHours()).padStart(2, '0');
          const mi = String(dt.getMinutes()).padStart(2, '0');
          return y + '-' + mo + '-' + d + ' ' + h + ':' + mi;
        }

        function renderLogLine(row){
          const line = document.createElement('div');
          line.className = 'term-line lvl-' + (row.level || 'info') + ((row.level || '') === 'error' ? ' is-halt-line' : '');
          line.setAttribute('data-line', 'log');
          line.setAttribute('data-search', ((row.datetime || '') + ' ' + (row.info || '')).toLowerCase());

          const ts = document.createElement('span');
          ts.className = 'term-time';
          ts.textContent = row.datetime || '-';

          const msg = document.createElement('span');
          msg.className = 'term-msg';

          if (row.tag){
            const tag = document.createElement('span');
            const tagKind = row.level === 'warning' ? 'warning' : (row.level || 'info');
            tag.className = 'term-tag tag-' + tagKind;
            tag.textContent = row.tag;
            msg.appendChild(tag);
          }

          const text = document.createElement('span');
          text.className = 'term-text';
          text.textContent = (row.tag ? (row.body || '') : (row.info || ''));
          msg.appendChild(text);

          line.appendChild(ts);
          line.appendChild(msg);
          return line;
        }

        function updateProgressVisual(summary){
          const step = Math.max(0, Math.min(10, Number(summary.step_number || 0)));
          const pct = Math.max(0, Math.min(100, Number(summary.step_progress_pct || 0)));
          const errorCount = Math.max(0, Number(summary.error_count || 0));
          const warnCount = Math.max(0, Number(summary.warn_count || 0));

          if (summary.has_error){
            stepProgressLabel.textContent = 'Deployment failed';
          } else if (summary.has_end){
            stepProgressLabel.textContent = 'Provisioning completed: Step ' + step + ' / 10';
          } else {
            stepProgressLabel.textContent = 'Provisioning in progress: Step ' + step + ' / 10';
          }

          stepProgressBar.style.width = (summary.has_error ? 100 : pct) + '%';
          stepProgressBar.innerHTML = summary.has_error
            ? '<span class="linear-error-text">&#9888; ' + errorCount + ' erreur' + (errorCount > 1 ? 's' : '') + ' | ' + warnCount + ' warning' + (warnCount > 1 ? 's' : '') + '</span>'
            : (pct + '%');

          stepProgressBar.classList.remove('state-success', 'state-error', 'state-idle', 'is-live');
          if (summary.has_error){
            stepProgressBar.classList.add('state-error');
          } else if (summary.has_end){
            stepProgressBar.classList.add('state-success');
          } else if (!summary.has_start){
            stepProgressBar.classList.add('state-idle');
          }
          if (summary.is_live){
            stepProgressBar.classList.add('is-live');
          }
        }

        let liveTimerActive = {{ 'true' if summary.is_live else 'false' }};
        let liveTimerStart = parseDbDateTime("{% if summary.start_ts %}{{ summary.start_ts.strftime('%Y-%m-%d %H:%M:%S') }}{% endif %}");

        function updateDurationFromState(summary){
          liveTimerActive = !!summary.is_live;
          liveTimerStart = parseDbDateTime(summary.start_ts || '');

          if (!liveTimerActive || !liveTimerStart){
            durationValue.textContent = summary.total_time || '-';
            return;
          }

          tickDuration();
        }

        function tickDuration(){
          if (!liveTimerActive || !liveTimerStart){
            return;
          }
          const secs = Math.floor((Date.now() - liveTimerStart.getTime()) / 1000);
          durationValue.innerHTML = '<span class="live-hourglass">&#x23F3;</span>' + formatElapsed(secs);
        }

        function applySummary(summary){
          if (!summary) return;

          statusBadge.textContent = summary.status_label || '-';
          statusBadge.className = 'status-badge status-large st-' + (summary.status_kind || 'idle');
          profileValue.textContent = summary.profile || '-';
          startValue.textContent = formatMinuteStamp(summary.start_ts || '');
          updateProgressVisual(summary);
          updateDurationFromState(summary);
        }

        function appendLine(row){
          if (terminalEmpty && terminalEmpty.parentNode){
            terminalEmpty.parentNode.removeChild(terminalEmpty);
          }

          const rowId = Number(row.id || 0);
          if (rowId > 0){
            if (renderedIds.has(rowId)){
              return;
            }
            renderedIds.add(rowId);
          }

          const line = renderLogLine(row);
          terminal.prepend(line);
        }

        function resetTerminal(){
          terminal.innerHTML = '';
          renderedIds.clear();
        }

        function trimTerminal(){
          const lines = terminal.children;
          if (lines.length <= maxLines) return;
          const toRemove = lines.length - trimTo;
          for (let i = 0; i < toRemove; i++){
            if (terminal.lastChild) {
              terminal.removeChild(terminal.lastChild);
            }
          }
        }

        async function pollLive(){
          if (pollInFlight){
            return;
          }
          pollInFlight = true;
          try {
            const resp = await fetch(liveUrl + '?after_id=' + encodeURIComponent(lastId), { cache: 'no-store' });
            if (!resp.ok) return;

            const payload = await resp.json();

            if (Array.isArray(payload.logs) && payload.logs.length){
              const resetIdx = payload.logs.findIndex((row) => /START PROVISION/i.test(String(row.info || '')));
              if (resetIdx !== -1){
                resetTerminal();
              }

              const rowsToRender = resetIdx !== -1 ? payload.logs.slice(resetIdx) : payload.logs;
              for (const row of rowsToRender){
                appendLine(row);
                if (row.id && row.id > lastId) {
                  lastId = row.id;
                }
              }

              trimTerminal();
            }

            applySummary(payload.summary || null);
          } catch (e) {
          } finally {
            pollInFlight = false;
          }
        }

        applySummary({
          status_kind: "{{ summary.status_kind }}",
          status_label: "{{ summary.status_label }}",
          profile: "{{ summary.profile }}",
          start_ts: "{% if summary.start_ts %}{{ summary.start_ts.strftime('%Y-%m-%d %H:%M:%S') }}{% endif %}",
          total_time: "{% if summary.total_time %}{{ format_td(summary.total_time) }}{% else %}-{% endif %}",
          step_number: {{ summary.step_number }},
          step_progress_pct: {{ summary.step_progress_pct }},
          issue_details: {{ summary.issue_details|tojson }},
          warn_count: {{ summary.warn_count }},
          error_count: {{ summary.error_count }},
          is_live: {{ 'true' if summary.is_live else 'false' }},
          has_start: {{ 'true' if summary.has_start else 'false' }},
          has_end: {{ 'true' if summary.has_end else 'false' }},
          has_error: {{ 'true' if summary.has_error else 'false' }}
        });

        setInterval(tickDuration, 1000);
        setInterval(pollLive, 2500);

        for (const rowEl of terminal.querySelectorAll('[data-log-id]')){
          const rowId = Number(rowEl.getAttribute('data-log-id') || 0);
          if (rowId > 0){
            renderedIds.add(rowId);
          }
        }

      })();
      </script>
    </body>
    </html>
    """

        return render_inline(
            tmpl,
            mac=mac_norm,
            compname=compname,
            logs_href=logs_href,
            rows=rows_view,
            summary=summary,
            format_td=_format_td,
            last_log_id=last_log_id,
        )


    @bp.route("/progress/<mac>/live.json")
    def progress_device_live_json(mac):
        mac_norm = normalize_id(mac)
        after_id = request.args.get("after_id", default=0, type=int)

        logs_conn = get_logs_db()
        conn = get_db()

        all_rows = logs_conn.execute(
            """
            SELECT id, datetime, info
            FROM deployment_info
            WHERE macaddress = ?
            ORDER BY id ASC;
            """,
            (mac_norm,),
        ).fetchall()

        comp_row = conn.execute(
            """
            SELECT computername, postype
            FROM newcomputer
            WHERE UPPER(REPLACE(REPLACE(REPLACE(macaddress, ':',''), '-',''), ' ','')) = ?
            LIMIT 1;
            """,
            (mac_norm,),
        ).fetchone()

        logs_conn.close()
        conn.close()

        postype = (comp_row["postype"] or "").strip() if comp_row else ""
        summary = _summarize_runs(all_rows, postype)

        out_rows = []
        new_rows = [r for r in all_rows if int(r["id"]) > (after_id or 0)]
        for r in _dedupe_rows(new_rows):
            rid = int(r["id"])
            tag, body = _split_log_tag(r["info"] or "")
            out_rows.append(
                {
                    "id": rid,
                    "datetime": r["datetime"],
                    "info": r["info"] or "",
                    "level": _log_level(r["info"] or ""),
                    "tag": tag,
                    "body": body,
                }
            )

        machine_name = (comp_row["computername"] or "").strip() if comp_row else ""

        return jsonify(
            {
                "mac": mac_norm,
                "machine_name": machine_name,
                "summary": _summary_to_json(summary),
                "logs": out_rows,
            }
        ), 200


    @bp.route("/progress.json")
    def progress_json():
        data = _collect_progress_by_device()

        out = {}
        for mac, s in data.items():
            payload = _summary_to_json(s)
            payload.update(
                {
                    "display": s.get("display") or mac,
                    "serial": s.get("serial") or mac,
                }
            )
            out[mac] = payload

        return jsonify(out), 200

    return bp


progress_bp = _build_progress_bp()
del _build_progress_bp


# ========================================================================
# Apps blueprint, formerly bp_apps.py
# ========================================================================
def _build_apps_bp():
    """
    bp_apps.py - Application Management Blueprint
    """

    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen

    from flask import Blueprint, abort, jsonify, redirect, request, session, url_for

    from core import get_db, require_roles, render_inline
    from core import as_reboot_flag, normalize_country_codes, normalize_model_patterns

    bp = Blueprint("apps", __name__)


    def _script_url(folder_url: str, script: str) -> str:
        folder = (folder_url or "").strip().rstrip("/")
        entry = (script or "").strip().lstrip("/")
        if folder and entry:
            return f"{folder}/{entry}"
        return folder or entry


    def _ensure_apps_columns(conn) -> None:
        for column, ddl in (
            ("script", "ALTER TABLE apps ADD COLUMN script TEXT NOT NULL DEFAULT 'install.ps1';"),
            ("allowed_models", "ALTER TABLE apps ADD COLUMN allowed_models TEXT NOT NULL DEFAULT '';"),
        ):
            try:
                conn.execute(f"SELECT {column} FROM apps LIMIT 1;")
            except Exception:
                conn.execute(ddl)
                conn.commit()


    @bp.route("/apps/check-link", methods=["POST"])
    @require_roles("admin", "operator")
    def app_check_link():
        data = request.get_json(silent=True) or {}
        target_url = _script_url(data.get("url") or request.form.get("url"), data.get("script") or request.form.get("script"))
        if not target_url:
            return jsonify(ok=False, message="URL is required."), 400

        def _probe(method: str):
            req = Request(target_url, method=method, headers={"User-Agent": "Tanium-Web-service-Provision/1.0"})
            if method == "GET":
                req.add_header("Range", "bytes=0-0")
            with urlopen(req, timeout=8) as resp:
                return int(getattr(resp, "status", None) or resp.getcode())

        try:
            status = _probe("HEAD")
        except HTTPError as ex:
            if ex.code in (405, 501):
                try:
                    status = _probe("GET")
                except HTTPError as ex2:
                    reachable = ex2.code in (401, 403)
                    return jsonify(ok=reachable, status=ex2.code, message="Resource exists but requires authentication." if reachable else f"HTTP {ex2.code}"), 200
                except URLError as ex2:
                    return jsonify(ok=False, message=f"Network error: {ex2.reason}"), 200
            else:
                reachable = ex.code in (401, 403)
                return jsonify(ok=reachable, status=ex.code, message="Resource exists but requires authentication." if reachable else f"HTTP {ex.code}"), 200
        except URLError as ex:
            return jsonify(ok=False, message=f"Network error: {ex.reason}"), 200
        except Exception as ex:
            return jsonify(ok=False, message=f"Check failed: {ex}"), 200

        ok = 200 <= status < 400
        return jsonify(ok=ok, status=status, message=f"Link reachable (HTTP {status})." if ok else f"Unexpected status: HTTP {status}."), 200


    @bp.route("/apps")
    def apps_list():
        sort = (request.args.get("sort") or "name").lower()
        direction = (request.args.get("dir") or "asc").lower()
        order = "DESC" if direction == "desc" else "ASC"
        order_clause = f"ORDER BY a.name COLLATE NOCASE {order}"
        sort = "name"

        conn = get_db()
        _ensure_apps_columns(conn)
        rows_db = conn.execute(
            """
            SELECT
              a.name, a.url, a.script, a.reboot,
              a.allowed_countries, a.blocked_countries, a.allowed_models,
              (SELECT COUNT(*) FROM postype_relations pr WHERE pr.application = a.name) AS use_count
            FROM apps a
            """
            + order_clause
            + ";"
        ).fetchall()
        usage_rows = conn.execute(
            """
            SELECT a.name AS app_name, pr.postype
            FROM postype_relations pr
            JOIN apps a ON a.name = pr.application
            WHERE pr.postype IS NOT NULL AND pr.postype <> ''
            ORDER BY a.name COLLATE NOCASE ASC, pr.postype COLLATE NOCASE ASC;
            """
        ).fetchall()
        conn.close()

        profile_map = {}
        for ur in usage_rows:
            app_name = ur["app_name"]
            pt = (ur["postype"] or "").strip()
            if pt:
                profile_map.setdefault(app_name, [])
                if pt not in profile_map[app_name]:
                    profile_map[app_name].append(pt)

        rows = []
        for r in rows_db:
            profiles = profile_map.get(r["name"], [])
            script_url = _script_url(r["url"], r["script"])
            rows.append(
                {
                    "name": r["name"],
                    "url": r["url"],
                    "script": r["script"],
                    "script_url": script_url,
                    "reboot": as_reboot_flag(r["reboot"]),
                    "allowed_countries": r["allowed_countries"],
                    "blocked_countries": r["blocked_countries"],
                    "allowed_models": r["allowed_models"],
                    "use_count": r["use_count"],
                    "usage_profiles_text": ", ".join(profiles) if profiles else "No profile uses this app",
                }
            )

        can_modify = (session.get("role") or "").lower() in ("admin", "operator")
        toggle_dir = "desc" if (sort == "name" and order == "ASC") else "asc"
        return render_inline(LIST_TEMPLATE, rows=rows, can_modify=can_modify, sort_name_href=url_for("apps.apps_list", sort="name", dir=toggle_dir))


    @bp.route("/apps/add", methods=["GET", "POST"])
    @require_roles("admin", "operator")
    def app_add():
        if request.method == "POST":
            name = request.form.get("name", "").strip()
            folder_url = request.form.get("url", "").strip().rstrip("/")
            script = request.form.get("script", "").strip()
            reboot = 1 if request.form.get("reboot") == "on" else 0
            allowed = normalize_country_codes(request.form.get("allowed_countries", ""))
            blocked = normalize_country_codes(request.form.get("blocked_countries", ""))
            allowed_models = normalize_model_patterns(request.form.get("allowed_models", ""))
            if not (name and folder_url and script):
                abort(400, "missing fields")

            conn = get_db()
            _ensure_apps_columns(conn)
            if conn.execute("SELECT 1 FROM apps WHERE name = ? LIMIT 1;", (name,)).fetchone() is not None:
                conn.close()
                abort(400, "application name already exists")
            conn.execute(
                """
                INSERT INTO apps (name, url, script, reboot, allowed_countries, blocked_countries, allowed_models)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                (name, folder_url, script, reboot, allowed, blocked, allowed_models),
            )
            conn.commit()
            conn.close()
            return redirect(url_for("apps.apps_list"))

        return render_inline(FORM_TEMPLATE, title="Add Application", row={}, action="Save")


    @bp.route("/apps/<path:app_name>/edit", methods=["GET", "POST"])
    @require_roles("admin", "operator")
    def app_edit(app_name):
        conn = get_db()
        _ensure_apps_columns(conn)
        if request.method == "POST":
            previous_name = app_name
            name = request.form.get("name", "").strip()
            folder_url = request.form.get("url", "").strip().rstrip("/")
            script = request.form.get("script", "").strip()
            reboot = 1 if request.form.get("reboot") == "on" else 0
            allowed = normalize_country_codes(request.form.get("allowed_countries", ""))
            blocked = normalize_country_codes(request.form.get("blocked_countries", ""))
            allowed_models = normalize_model_patterns(request.form.get("allowed_models", ""))
            if not (name and folder_url and script):
                conn.close()
                abort(400, "missing fields")
            duplicate = conn.execute(
                "SELECT 1 FROM apps WHERE name = ? AND name <> ? LIMIT 1;",
                (name, previous_name),
            ).fetchone()
            if duplicate is not None:
                conn.close()
                abort(400, "application name already exists")

            conn.execute(
                """
                UPDATE apps
                   SET name = ?, url = ?, script = ?, reboot = ?,
                       allowed_countries = ?, blocked_countries = ?, allowed_models = ?
                 WHERE name = ?;
                """,
                (name, folder_url, script, reboot, allowed, blocked, allowed_models, previous_name),
            )
            if previous_name != name:
                conn.execute(
                    "UPDATE postype_relations SET application = ? WHERE application = ?;",
                    (name, previous_name),
                )
            conn.commit()
            conn.close()
            return redirect(url_for("apps.apps_list"))

        row = conn.execute(
            """
            SELECT name, url, script, reboot, allowed_countries, blocked_countries, allowed_models
            FROM apps
            WHERE name = ?
            LIMIT 1;
            """,
            (app_name,),
        ).fetchone()
        conn.close()
        if row is None:
            abort(404, "app not found")

        data = {k: row[k] for k in row.keys()}
        data["reboot"] = as_reboot_flag(data.get("reboot"))
        return render_inline(FORM_TEMPLATE, title=f"Edit Application - {app_name}", row=data, action="Save")


    @bp.route("/apps/<path:app_name>/delete", methods=["POST"])
    @require_roles("admin", "operator")
    def app_delete(app_name):
        conn = get_db()
        conn.execute("DELETE FROM postype_relations WHERE application = ?;", (app_name,))
        conn.execute("DELETE FROM apps WHERE name = ?;", (app_name,))
        conn.commit()
        conn.close()
        return redirect(url_for("apps.apps_list"))


    LIST_TEMPLATE = r"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <title>Applications</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
      <link href="{{ url_for('static', filename='theme-pro.css') }}" rel="stylesheet">
      <script defer src="{{ url_for('static', filename='app-shell.js') }}" data-app-shell="1" data-username="{{ session.get('username', '') }}" data-role="{{ session.get('role', '') }}"></script>
      <style>
        body{font-family:Inter,Roboto,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        .app-delete-btn{
          width:36px;
          height:36px;
          border-radius:10px;
          border:1px solid #f1c0c5;
          background:#fff0f1;
          color:#b91c1c;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
        }
        .app-delete-btn svg{
          width:16px;
          height:16px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .app-delete-btn:hover{
          border-color:#e9a8af;
          background:#ffe3e6;
          color:#991b1b;
          transform:translateY(-1px);
          box-shadow:0 6px 14px rgba(0,0,0,.1);
        }
        .app-folder-url{
          margin-top:.35rem;
          word-break:break-all;
          font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
          font-size:.78rem;
          color:#52657a;
        }
        .app-meta{
          display:flex;
          align-items:center;
          gap:.45rem;
          margin-top:.45rem;
        }
        .status-badge{
          display:inline-flex;
          align-items:center;
          width:max-content;
          border-radius:999px;
          border:1px solid transparent;
          padding:.18rem .52rem;
          font-size:.72rem;
          font-weight:800;
          line-height:1;
        }
        .status-warning{
          color:#8d5d00;
          background:rgba(255,176,32,.2);
          border-color:rgba(141,93,0,.35);
        }
      </style>
    </head>
    <body class="min-h-screen bg-slate-50 text-slate-900">
      <div class="container-fluid">
      <main class="mx-auto max-w-[1800px] px-8 py-8">
        <div class="mb-6 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">Administration</p>
            <h1 class="mt-2 text-3xl font-extrabold tracking-tight text-slate-950">Applications</h1>
          </div>
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
            <div class="relative">
              <svg class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="11" cy="11" r="7"></circle><path d="M20 20l-3.2-3.2"></path>
              </svg>
              <input id="search" class="h-11 w-full rounded-xl border border-slate-200 bg-white pl-10 pr-4 text-sm text-slate-700 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-sky-400 focus:ring-4 focus:ring-sky-100 sm:w-80" type="search" placeholder="Search application">
            </div>
            {% if can_modify %}
            <a class="btn-primary-green" href="{{ url_for('apps.app_add') }}">+ Add</a>
            {% endif %}
          </div>
        </div>

        <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div class="max-h-[calc(100vh-190px)] overflow-auto">
            <table id="items" class="standard-list-table min-w-full table-fixed divide-y divide-slate-200">
              <thead class="sticky top-0 z-10 bg-slate-100/95 backdrop-blur">
                <tr class="text-left text-xs font-bold uppercase tracking-wide text-slate-500">
                  <th class="w-[90%] px-6 py-4"><a class="text-slate-600 no-underline hover:text-slate-950" href="{{ sort_name_href }}">Application</a></th>
                  {% if can_modify %}<th class="w-[10%] px-6 py-4 text-right"></th>{% endif %}
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-100 bg-white text-sm">
            {% for row in rows %}
              <tr class="app-row group odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60" data-search="{{ (row.name ~ ' ' ~ row.url ~ ' ' ~ (row.allowed_models or ''))|lower }}">
                <td class="px-6 py-3 align-middle">
                  {% if can_modify %}
                  <a class="font-semibold text-slate-900 no-underline hover:text-sky-700" href="{{ url_for('apps.app_edit', app_name=row.name) }}">{{ row.name }}</a>
                  {% else %}
                  <span class="font-semibold text-slate-900">{{ row.name }}</span>
                  {% endif %}
                  {% if row.url %}
                  <div class="app-folder-url">{{ row.url }}</div>
                  {% endif %}
                  {% if row.reboot %}
                  <div class="app-meta">
                    <span class="status-badge status-warning">Reboot</span>
                  </div>
                  {% endif %}
                  {% if row.allowed_models %}
                  <div class="app-folder-url">Models: {{ row.allowed_models }}</div>
                  {% endif %}
                </td>
                {% if can_modify %}
                <td class="px-6 py-3 text-right align-middle">
                  <form method="post" action="{{ url_for('apps.app_delete', app_name=row.name) }}" class="m-0" onsubmit="return confirm('Delete this application?');">
                    <button class="app-delete-btn" type="submit" title="Supprimer {{ row.name }}" aria-label="Supprimer {{ row.name }}">
                      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6l1-2h6l1 2"></path><path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path><path d="M14 10v6"></path></svg>
                    </button>
                  </form>
                </td>
                {% endif %}
              </tr>
            {% endfor %}
              </tbody>
            </table>
          </div>
        </section>
      </main>
      </div>
      <script>
      (function(){
        const input=document.getElementById('search');
        const rows=Array.from(document.querySelectorAll('#items tbody tr'));
        input.addEventListener('input',()=>{const q=(input.value||'').toLowerCase();rows.forEach(r=>r.style.display=(r.dataset.search||'').includes(q)?'':'none')});

      })();
      </script>
    </body>
    </html>
    """


    FORM_TEMPLATE = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>{{ title }}</title>
    __HEAD_ASSETS__
      <style>
        body{background:#edf3f8;color:#203044}.card{background:#fff;border:1px solid #d8e2ec}
        .form-control{background:#fff!important;color:#203044!important;border:1px solid #cbd7e3!important}
        .form-label{color:#203044}.form-text{color:#5d7085}.check-result.ok{color:#12824a}.check-result.ko{color:#c62828}.check-result.pending{color:#0b6fae}
        .form-check-label{color:#203044}
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">
        <h1 class="mb-4">{{ title }}</h1>
        <form method="post" class="card p-3">
          <div class="mb-3">
            <label class="form-label fw-bold">Name</label>
            <input id="name-field" type="text" name="name" class="form-control" value="{{ row.name or '' }}" required>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">URL folder</label>
            <input id="url-field" type="text" name="url" class="form-control" value="{{ row.url or '' }}" required>
            <button type="button" class="btn btn-outline-info btn-sm mt-2" onclick="openFilePicker()">Browse...</button>
            <div class="form-text">Ex: https://provision.example.local/file/Deploy/7ZIP</div>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Script</label>
            <input id="script-field" type="text" name="script" class="form-control" value="{{ row.script or 'install.ps1' }}" required>
            <button type="button" class="btn btn-outline-info btn-sm mt-2" onclick="openScriptPicker()">Browse...</button>
          </div>
          <div class="form-check mb-3">
            <input class="form-check-input" type="checkbox" id="reboot" name="reboot" {% if row.reboot %}checked{% endif %}>
            <label class="form-check-label" for="reboot">Reboot required</label>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Allowed Countries</label>
            <input type="text" name="allowed_countries" class="form-control" value="{{ row.allowed_countries or '' }}">
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Blocked Countries</label>
            <input type="text" name="blocked_countries" class="form-control" value="{{ row.blocked_countries or '' }}">
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Allowed Models (regex)</label>
            <input type="text" name="allowed_models" class="form-control" value="{{ row.allowed_models or '' }}">
            <div class="form-text">Regex séparées par ;. Vide = tous les modèles.</div>
          </div>
          <div class="d-flex gap-2">
            <button class="btn btn-primary" type="submit">{{ action }}</button>
            <a class="btn btn-secondary" href="{{ url_for('apps.apps_list') }}">Cancel</a>
          </div>
        </form>
      </div>
      <script>
      let pickerMode = 'folder';
      const filesRoot = '{{ url_for("files.list_dir") }}';

      function folderUrlToPickerUrl(folderUrl){
        let value = (folderUrl || '').trim();
        if (!value) return filesRoot + '?picker=1';
        try { value = new URL(value, window.location.origin).pathname; } catch(e) {}
        value = value.replace(/\\/g, '/');
        const marker = '/file/';
        const idx = value.toLowerCase().indexOf(marker);
        if (idx < 0) return filesRoot + '?picker=1';
        const subpath = value.substring(idx + marker.length).replace(/^\/+|\/+$/g, '');
        const encoded = subpath.split('/').filter(Boolean).map(function(part){
          try { part = decodeURIComponent(part); } catch(e) {}
          return encodeURIComponent(part);
        }).join('/');
        return filesRoot.replace(/\/$/, '') + '/' + encoded + '?picker=1';
      }

      function openFilePicker(){
        pickerMode = 'folder';
        window.open(filesRoot + '?picker=1&picker_target=folder','filePicker','width=1000,height=700,resizable=yes,scrollbars=yes');
      }

      function openScriptPicker(){
        pickerMode = 'script';
        window.open(folderUrlToPickerUrl(document.getElementById('url-field').value),'filePicker','width=1000,height=700,resizable=yes,scrollbars=yes');
      }

      function setPickedFileUrl(url){
        let decoded=url||''; try{decoded=decodeURI(decoded)}catch(e){}
        decoded=decoded.split('?')[0].split('#')[0].replace(/\\/g,'/');
        if (pickerMode === 'folder'){
          document.getElementById('url-field').value = decoded.replace(/\/+$/, '');
          return;
        }
        const folder = (document.getElementById('url-field').value || '').trim().replace(/\/+$/, '');
        if (pickerMode === 'script'){
          const picked = decoded.replace(/\/+$/, '');
          let relative = picked;
          if (folder && picked.toLowerCase().startsWith(folder.toLowerCase() + '/')){
            relative = picked.substring(folder.length + 1);
          } else {
            const idx = picked.lastIndexOf('/');
            relative = idx >= 0 ? picked.substring(idx + 1) : picked;
          }
          document.getElementById('script-field').value = relative || 'install.ps1';
          return;
        }
        const idx=decoded.lastIndexOf('/');
        if(idx>=0){
          if (/\.[^./]+$/.test(decoded.substring(idx+1))){
            document.getElementById('url-field').value=decoded.substring(0,idx);
            document.getElementById('script-field').value=decoded.substring(idx+1)||'install.ps1';
          } else {
            document.getElementById('url-field').value=decoded.replace(/\/+$/, '');
          }
        } else {
          document.getElementById('url-field').value=decoded;
        }
      }
      </script>
    </body>
    </html>
    """

    return bp


apps_bp = _build_apps_bp()
del _build_apps_bp


# ========================================================================
# Configs blueprint, formerly bp_configs.py
# ========================================================================
def _build_configs_bp():
    """
    bp_configs.py - Configuration Management Blueprint
    """

    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen

    from flask import Blueprint, abort, jsonify, redirect, request, session, url_for

    from core import get_db, require_roles, render_inline
    from core import as_reboot_flag, normalize_country_codes

    bp = Blueprint("configs", __name__)


    def _script_url(folder_url: str, script: str) -> str:
        folder = (folder_url or "").strip().rstrip("/")
        entry = (script or "").strip().lstrip("/")
        if folder and entry:
            return f"{folder}/{entry}"
        return folder or entry


    def _next_config_id(conn) -> int:
        row = conn.execute("SELECT COALESCE(MAX(TRY_CAST(id AS BIGINT)), 0) + 1 AS next_id FROM configs;").fetchone()
        return int(row["next_id"] if row and row["next_id"] is not None else 1)


    def _ensure_configs_columns(conn) -> None:
        for column, ddl in (
            ("reboot", "ALTER TABLE configs ADD COLUMN reboot INTEGER NOT NULL DEFAULT 0;"),
            ("script", "ALTER TABLE configs ADD COLUMN script TEXT NOT NULL DEFAULT 'install.ps1';"),
            ("AdditionalLog", "ALTER TABLE configs ADD COLUMN AdditionalLog TEXT NOT NULL DEFAULT '';"),
        ):
            try:
                conn.execute(f"SELECT {column} FROM configs LIMIT 1;")
            except Exception:
                conn.execute(ddl)
                conn.commit()


    @bp.route("/configs/check-link", methods=["POST"])
    @require_roles("admin", "operator")
    def config_check_link():
        data = request.get_json(silent=True) or {}
        target_url = _script_url(data.get("url") or request.form.get("url"), data.get("script") or request.form.get("script"))
        if not target_url:
            return jsonify(ok=False, message="URL is required."), 400

        def _probe(method: str):
            req = Request(target_url, method=method, headers={"User-Agent": "Tanium-Web-service-Provision/1.0"})
            if method == "GET":
                req.add_header("Range", "bytes=0-0")
            with urlopen(req, timeout=8) as resp:
                return int(getattr(resp, "status", None) or resp.getcode())

        try:
            status = _probe("HEAD")
        except HTTPError as ex:
            if ex.code in (405, 501):
                try:
                    status = _probe("GET")
                except HTTPError as ex2:
                    reachable = ex2.code in (401, 403)
                    return jsonify(ok=reachable, status=ex2.code, message="Resource exists but requires authentication." if reachable else f"HTTP {ex2.code}"), 200
                except URLError as ex2:
                    return jsonify(ok=False, message=f"Network error: {ex2.reason}"), 200
            else:
                reachable = ex.code in (401, 403)
                return jsonify(ok=reachable, status=ex.code, message="Resource exists but requires authentication." if reachable else f"HTTP {ex.code}"), 200
        except URLError as ex:
            return jsonify(ok=False, message=f"Network error: {ex.reason}"), 200
        except Exception as ex:
            return jsonify(ok=False, message=f"Check failed: {ex}"), 200

        ok = 200 <= status < 400
        return jsonify(ok=ok, status=status, message=f"Link reachable (HTTP {status})." if ok else f"Unexpected status: HTTP {status}."), 200


    @bp.route("/configs")
    def configs_list():
        sort = (request.args.get("sort") or "name").lower()
        direction = (request.args.get("dir") or "asc").lower()
        order = "DESC" if direction == "desc" else "ASC"
        if sort == "id":
            order_clause = f"ORDER BY c.id {order}"
        else:
            order_clause = f"ORDER BY c.name COLLATE NOCASE {order}"
            sort = "name"

        conn = get_db()
        _ensure_configs_columns(conn)
        rows_db = conn.execute(
            """
            SELECT
              c.id, c.name, c.url, c.script, c.AdditionalLog, c.reboot,
              c.allowed_countries, c.blocked_countries,
              0 AS use_count
            FROM configs c
            """
            + order_clause
            + ";"
        ).fetchall()
        usage_rows = []
        conn.close()

        profile_map = {}
        for ur in usage_rows:
            cid = ur["config_id"]
            pt = (ur["postype"] or "").strip()
            if pt:
                profile_map.setdefault(cid, [])
                if pt not in profile_map[cid]:
                    profile_map[cid].append(pt)

        rows = []
        for r in rows_db:
            profiles = profile_map.get(r["id"], [])
            rows.append(
                {
                    "id": r["id"],
                    "name": r["name"],
                    "url": r["url"],
                    "script": r["script"],
                    "AdditionalLog": r["AdditionalLog"],
                    "script_url": _script_url(r["url"], r["script"]),
                    "reboot": as_reboot_flag(r["reboot"]),
                    "allowed_countries": r["allowed_countries"],
                    "blocked_countries": r["blocked_countries"],
                    "use_count": r["use_count"],
                    "usage_profiles_text": ", ".join(profiles) if profiles else "No profile uses this configuration",
                }
            )

        can_modify = (session.get("role") or "").lower() in ("admin", "operator")
        toggle_dir = "desc" if (sort == "name" and order == "ASC") else "asc"
        return render_inline(LIST_TEMPLATE, rows=rows, can_modify=can_modify, sort_name_href=url_for("configs.configs_list", sort="name", dir=toggle_dir))


    @bp.route("/configs/add", methods=["GET", "POST"])
    @require_roles("admin", "operator")
    def config_add():
        if request.method == "POST":
            conn = get_db()
            _ensure_configs_columns(conn)
            name = request.form.get("name", "").strip()
            folder_url = request.form.get("url", "").strip().rstrip("/")
            script = request.form.get("script", "").strip()
            additional_log = request.form.get("AdditionalLog", "").strip()
            reboot = 1 if request.form.get("reboot") == "on" else 0
            allowed = normalize_country_codes(request.form.get("allowed_countries", ""))
            blocked = normalize_country_codes(request.form.get("blocked_countries", ""))
            if not (name and folder_url and script):
                conn.close()
                abort(400, "missing fields")

            conn.execute(
                """
                INSERT INTO configs (id, name, url, script, AdditionalLog, reboot, allowed_countries, blocked_countries)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                (_next_config_id(conn), name, folder_url, script, additional_log, reboot, allowed, blocked),
            )
            conn.commit()
            conn.close()
            return redirect(url_for("configs.configs_list"))

        return render_inline(FORM_TEMPLATE, title="Add Configuration", row={}, action="Save")


    @bp.route("/configs/<int:config_id>/edit", methods=["GET", "POST"])
    @require_roles("admin", "operator")
    def config_edit(config_id):
        conn = get_db()
        _ensure_configs_columns(conn)
        if request.method == "POST":
            name = request.form.get("name", "").strip()
            folder_url = request.form.get("url", "").strip().rstrip("/")
            script = request.form.get("script", "").strip()
            additional_log = request.form.get("AdditionalLog", "").strip()
            reboot = 1 if request.form.get("reboot") == "on" else 0
            allowed = normalize_country_codes(request.form.get("allowed_countries", ""))
            blocked = normalize_country_codes(request.form.get("blocked_countries", ""))
            if not (name and folder_url and script):
                conn.close()
                abort(400, "missing fields")

            conn.execute(
                """
                UPDATE configs
                   SET name = ?, url = ?, script = ?, AdditionalLog = ?, reboot = ?,
                       allowed_countries = ?, blocked_countries = ?
                 WHERE id = ?;
                """,
                (name, folder_url, script, additional_log, reboot, allowed, blocked, config_id),
            )
            conn.commit()
            conn.close()
            return redirect(url_for("configs.configs_list"))

        row = conn.execute(
            """
            SELECT id, name, url, script, AdditionalLog, reboot, allowed_countries, blocked_countries
            FROM configs
            WHERE id = ?
            LIMIT 1;
            """,
            (config_id,),
        ).fetchone()
        conn.close()
        if row is None:
            abort(404, "configuration not found")

        data = {k: row[k] for k in row.keys()}
        data["reboot"] = as_reboot_flag(data.get("reboot"))
        return render_inline(FORM_TEMPLATE, title=f"Edit Configuration #{config_id}", row=data, action="Save")


    @bp.route("/configs/<int:config_id>/delete", methods=["POST"])
    @require_roles("admin", "operator")
    def config_delete(config_id):
        conn = get_db()
        conn.execute("DELETE FROM configs WHERE id = ?;", (config_id,))
        conn.commit()
        conn.close()
        return redirect(url_for("configs.configs_list"))


    LIST_TEMPLATE = r"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <title>Configurations</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
      <link href="{{ url_for('static', filename='theme-pro.css') }}" rel="stylesheet">
      <script defer src="{{ url_for('static', filename='app-shell.js') }}" data-app-shell="1" data-username="{{ session.get('username', '') }}" data-role="{{ session.get('role', '') }}"></script>
      <style>
        body{font-family:Inter,Roboto,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        .cfg-inline-details{margin-top:.45rem}
      </style>
    </head>
    <body class="min-h-screen bg-slate-50 text-slate-900">
      <div class="container-fluid">
      <main class="mx-auto max-w-[1800px] px-8 py-8">
        <div class="mb-6 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">Administration</p>
            <h1 class="mt-2 text-3xl font-extrabold tracking-tight text-slate-950">Configuration</h1>
          </div>
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
            <div class="relative">
              <svg class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="11" cy="11" r="7"></circle><path d="M20 20l-3.2-3.2"></path>
              </svg>
              <input id="search" class="h-11 w-full rounded-xl border border-slate-200 bg-white pl-10 pr-4 text-sm text-slate-700 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-sky-400 focus:ring-4 focus:ring-sky-100 sm:w-80" type="search" placeholder="Search configuration">
            </div>
            {% if can_modify %}
            <a class="btn-primary-green" href="{{ url_for('configs.config_add') }}">+ Add</a>
            {% endif %}
          </div>
        </div>

        <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div class="max-h-[calc(100vh-190px)] overflow-auto">
            <table id="items" class="standard-list-table min-w-full table-fixed divide-y divide-slate-200">
              <thead class="sticky top-0 z-10 bg-slate-100/95 backdrop-blur">
                <tr class="text-left text-xs font-bold uppercase tracking-wide text-slate-500">
                  <th class="w-[68%] px-6 py-4"><a class="text-slate-600 no-underline hover:text-slate-950" href="{{ sort_name_href }}">Configuration</a></th>
                  <th class="w-[10%] px-6 py-4">RBT</th>
                  <th class="w-[12%] px-6 py-4 text-center">Usage</th>
                  {% if can_modify %}<th class="w-[10%] px-6 py-4 text-right">Action</th>{% endif %}
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-100 bg-white text-sm">
            {% for row in rows %}
              <tr class="cfg-row group odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60" data-search="{{ (row.name ~ ' ' ~ row.url ~ ' ' ~ row.script ~ ' ' ~ row.AdditionalLog ~ ' ' ~ row.usage_profiles_text)|lower }}">
                <td class="px-6 py-3 align-middle">
                  {% if can_modify %}
                  <a class="font-semibold text-slate-900 no-underline hover:text-sky-700" href="{{ url_for('configs.config_edit', config_id=row.id) }}">{{ row.name }}</a>
                  {% else %}
                  <span class="font-semibold text-slate-900">{{ row.name }}</span>
                  {% endif %}
                  <div class="mt-1 text-xs font-medium text-slate-400">ID #{{ row.id }}</div>
                  <div class="cfg-inline-details rounded-lg border border-slate-200 bg-white/80 p-2.5">
                    <div class="grid gap-2 xl:grid-cols-[90px_1fr]">
                      {% if row.url %}
                      <div class="text-[11px] font-bold uppercase tracking-wide text-slate-400">Folder</div>
                      <div class="break-all font-mono text-xs text-slate-700">{{ row.url }}</div>
                      {% endif %}
                      {% if row.script %}
                      <div class="text-[11px] font-bold uppercase tracking-wide text-slate-400">Script</div>
                      <div class="break-all font-mono text-xs text-slate-700">{{ row.script }}</div>
                      {% endif %}
                      {% if row.AdditionalLog %}
                      <div class="text-[11px] font-bold uppercase tracking-wide text-slate-400">Log</div>
                      <div class="break-all font-mono text-xs text-slate-700">{{ row.AdditionalLog }}</div>
                      {% endif %}
                      {% if row.allowed_countries %}
                      <div class="text-[11px] font-bold uppercase tracking-wide text-slate-400">Allowed</div>
                      <div class="break-all font-mono text-xs text-slate-700">{{ row.allowed_countries }}</div>
                      {% endif %}
                      {% if row.blocked_countries %}
                      <div class="text-[11px] font-bold uppercase tracking-wide text-slate-400">Blocked</div>
                      <div class="break-all font-mono text-xs text-slate-700">{{ row.blocked_countries }}</div>
                      {% endif %}
                    </div>
                  </div>
                </td>
                <td class="px-6 py-3 align-middle">
                  {% if row.reboot %}
                  <span class="status-badge status-warning">Reboot</span>
                  {% endif %}
                </td>
                <td class="px-6 py-3 text-center align-middle">
                  <span class="usage-count-badge" title="{{ row.usage_profiles_text }}">{{ row.use_count }}</span>
                </td>
                {% if can_modify %}
                <td class="px-6 py-3 text-right align-middle">
                  <div class="action-menu-wrap">
                    <button class="action-menu-trigger" type="button" aria-label="Actions" aria-expanded="false">⋮</button>
                    <div class="action-menu-dropdown">
                      <a class="action-menu-item" href="{{ url_for('configs.config_edit', config_id=row.id) }}">Éditer</a>
                      <form method="post" action="{{ url_for('configs.config_delete', config_id=row.id) }}" class="m-0" onsubmit="return confirm('Delete this configuration?');">
                        <button class="action-menu-item action-menu-delete" type="submit">Supprimer</button>
                      </form>
                    </div>
                  </div>
                </td>
                {% endif %}
              </tr>
            {% endfor %}
              </tbody>
            </table>
          </div>
        </section>
      </main>
      </div>
      <script>
      (function(){
        const input=document.getElementById('search');
        const rows=Array.from(document.querySelectorAll('#items tbody tr'));
        input.addEventListener('input',()=>{const q=(input.value||'').toLowerCase();rows.forEach(r=>r.style.display=(r.dataset.search||'').includes(q)?'':'none')});

        function closeActionMenus(except){
          document.querySelectorAll('.action-menu-wrap.is-open').forEach(menu=>{
            if(menu !== except){
              menu.classList.remove('is-open');
              const btn = menu.querySelector('.action-menu-trigger');
              if(btn) btn.setAttribute('aria-expanded', 'false');
            }
          });
        }
        document.querySelectorAll('.action-menu-trigger').forEach(btn=>{
          btn.addEventListener('click', ev=>{
            ev.stopPropagation();
            const wrap = btn.closest('.action-menu-wrap');
            const willOpen = !wrap.classList.contains('is-open');
            closeActionMenus(wrap);
            wrap.classList.toggle('is-open', willOpen);
            btn.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
          });
        });
        document.addEventListener('click',()=>closeActionMenus(null));
      })();
      </script>
    </body>
    </html>
    """


    FORM_TEMPLATE = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>{{ title }}</title>
    __HEAD_ASSETS__
      <style>
        body{background:#edf3f8;color:#203044}.card{background:#fff;border:1px solid #d8e2ec}
        .form-control{background:#fff!important;color:#203044!important;border:1px solid #cbd7e3!important}
        .form-label{color:#203044}.form-text{color:#5d7085}.check-result.ok{color:#12824a}.check-result.ko{color:#c62828}.check-result.pending{color:#0b6fae}
        .form-check-label{color:#203044}
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">
        <h1 class="mb-4">{{ title }}</h1>
        <form method="post" class="card p-3">
          <div class="mb-3">
            <label class="form-label fw-bold">Name</label>
            <input id="name-field" type="text" name="name" class="form-control" value="{{ row.name or '' }}" required>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">URL folder</label>
            <input id="url-field" type="text" name="url" class="form-control" value="{{ row.url or '' }}" required>
            <button type="button" class="btn btn-outline-info btn-sm mt-2" onclick="openFilePicker()">Browse...</button>
            <div class="form-text">Ex: https://provision.example.local/file/Packages/Cash-SystemConf/CFG-XXX</div>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Script</label>
            <input id="script-field" type="text" name="script" class="form-control" value="{{ row.script or 'install.ps1' }}" required>
            <button type="button" class="btn btn-outline-info btn-sm mt-2" onclick="openScriptPicker()">Browse...</button>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">AdditionalLog</label>
            <input type="text" name="AdditionalLog" class="form-control" value="{{ row.AdditionalLog or '' }}">
          </div>
          <div class="form-check mb-3">
            <input class="form-check-input" type="checkbox" id="reboot" name="reboot" {% if row.reboot %}checked{% endif %}>
            <label class="form-check-label" for="reboot">Reboot required</label>
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Allowed Countries</label>
            <input type="text" name="allowed_countries" class="form-control" value="{{ row.allowed_countries or '' }}">
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold">Blocked Countries</label>
            <input type="text" name="blocked_countries" class="form-control" value="{{ row.blocked_countries or '' }}">
          </div>
          <div class="d-flex gap-2">
            <button class="btn btn-primary" type="submit">{{ action }}</button>
            <a class="btn btn-secondary" href="{{ url_for('configs.configs_list') }}">Cancel</a>
          </div>
        </form>
      </div>
      <script>
      let pickerMode = 'folder';
      const filesRoot = '{{ url_for("files.list_dir") }}';

      function folderUrlToPickerUrl(folderUrl){
        let value = (folderUrl || '').trim();
        if (!value) return filesRoot + '?picker=1';
        try { value = new URL(value, window.location.origin).pathname; } catch(e) {}
        value = value.replace(/\\/g, '/');
        const marker = '/file/';
        const idx = value.toLowerCase().indexOf(marker);
        if (idx < 0) return filesRoot + '?picker=1';
        const subpath = value.substring(idx + marker.length).replace(/^\/+|\/+$/g, '');
        const encoded = subpath.split('/').filter(Boolean).map(function(part){
          try { part = decodeURIComponent(part); } catch(e) {}
          return encodeURIComponent(part);
        }).join('/');
        return filesRoot.replace(/\/$/, '') + '/' + encoded + '?picker=1';
      }

      function openFilePicker(){
        pickerMode = 'folder';
        window.open(filesRoot + '?picker=1&picker_target=folder','filePicker','width=1000,height=700,resizable=yes,scrollbars=yes');
      }

      function openScriptPicker(){
        pickerMode = 'script';
        window.open(folderUrlToPickerUrl(document.getElementById('url-field').value),'filePicker','width=1000,height=700,resizable=yes,scrollbars=yes');
      }

      function setPickedFileUrl(url){
        let decoded=url||''; try{decoded=decodeURI(decoded)}catch(e){}
        decoded=decoded.split('?')[0].split('#')[0].replace(/\\/g,'/');
        if (pickerMode === 'folder'){
          document.getElementById('url-field').value = decoded.replace(/\/+$/, '');
          return;
        }
        const folder = (document.getElementById('url-field').value || '').trim().replace(/\/+$/, '');
        if (pickerMode === 'script'){
          const picked = decoded.replace(/\/+$/, '');
          let relative = picked;
          if (folder && picked.toLowerCase().startsWith(folder.toLowerCase() + '/')){
            relative = picked.substring(folder.length + 1);
          } else {
            const idx = picked.lastIndexOf('/');
            relative = idx >= 0 ? picked.substring(idx + 1) : picked;
          }
          document.getElementById('script-field').value = relative || 'install.ps1';
          return;
        }
        const idx=decoded.lastIndexOf('/');
        if(idx>=0){
          if (/\.[^./]+$/.test(decoded.substring(idx+1))){
            document.getElementById('url-field').value=decoded.substring(0,idx);
            document.getElementById('script-field').value=decoded.substring(idx+1)||'install.ps1';
          } else {
            document.getElementById('url-field').value=decoded.replace(/\/+$/, '');
          }
        } else {
          document.getElementById('url-field').value=decoded;
        }
      }
      </script>
    </body>
    </html>
    """

    return bp


configs_bp = _build_configs_bp()
del _build_configs_bp


# ========================================================================
# Users blueprint, formerly bp_users.py
# ========================================================================
def _build_users_bp():
    """
    =============================================================================
    bp_users.py - User Account Management Blueprint
    =============================================================================

    Manages user accounts and role-based access control (RBAC).

    Features:
      - User account CRUD operations (admin only)
      - Role management (admin, operator, viewer)
      - Password management
      - Track user login history
      - Builtin admin account protection
    """

    import re
    from datetime import datetime
    from flask import Blueprint, request, redirect, url_for, abort, session
    from core import get_db, require_roles, render_inline
    from werkzeug.security import generate_password_hash

    bp = Blueprint("users", __name__)

    # ---------- Helpers ----------
    def _hash_password(plain: str):
        # Keep same scheme as core.authenticate (Werkzeug PBKDF2-SHA256)
        return generate_password_hash(plain or "", method="pbkdf2:sha256", salt_length=16)

    def _is_builtin_admin(row):
        if not row:
            return False
        u = (dict(row).get("username", "") or "").strip().lower()
        return u == "admin"

    def _next_user_id(conn) -> str:
        rows = conn.execute("SELECT id FROM users;").fetchall()
        max_id = 0
        for row in rows:
            try:
                value = int(str(row["id"] or "").strip())
            except Exception:
                continue
            max_id = max(max_id, value)
        return str(max_id + 1)

    def _format_user_datetime(value):
        txt = (value or "").strip()
        if not txt:
            return ""
        candidate = txt.replace("Z", "+00:00")
        try:
            dt = datetime.fromisoformat(candidate)
            return dt.strftime("%Y-%m-%d %H:%M")
        except Exception:
            pass
        m = re.match(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})", txt)
        if m:
            return f"{m.group(1)} {m.group(2)}"
        return txt

    # ---------- LIST ----------
    @bp.route("/users")
    @require_roles('admin')   # <-- admin only
    def users_list():
        conn = get_db()
        rows_db = conn.execute(
            """
            SELECT username
            FROM users
            ORDER BY LOWER(username);
            """
        ).fetchall()
        conn.close()

        rows = []
        current_username = ((session.get("username") or "").strip().lower())
        for r in rows_db:
            item = dict(r)
            uname = ((item.get("username") or "").strip())
            if not uname:
                continue
            item["is_builtin_admin"] = _is_builtin_admin(item)
            item["is_current_user"] = (uname.lower() == current_username)
            rows.append(item)

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Users</title>
      <script src="https://cdn.tailwindcss.com"></script>
    __HEAD_ASSETS__
      <style>
        body{background:#f8fafc; color:#0f172a}
        a, a:hover{color:#1d6fd1}
        .empty-dash{opacity:.3}

        .header-main{
          display:grid;
          grid-template-columns:minmax(220px,1fr) auto;
          align-items:center;
          gap:1rem;
          margin-bottom:1.5rem;
        }
        .header-left{
          min-width:0;
        }
        .page-kicker{
          margin:0;
          color:#94a3b8;
          font-size:.75rem;
          font-weight:700;
          letter-spacing:.22em;
          text-transform:uppercase;
        }
        .header-left h1{
          margin:.5rem 0 0;
          color:#020617!important;
          line-height:1.05;
          font-size:1.875rem;
          font-weight:800;
          letter-spacing:-.025em;
        }
        .toolbar{
          display:flex;
          align-items:center;
          justify-content:flex-end;
          gap:.75rem;
          flex-wrap:wrap;
        }

        .time{color:#64748b!important}
        .username-cell{font-weight:700}
        .user-row{cursor:pointer}
        .user-edit-link{color:inherit; text-decoration:none}
        .user-edit-link:hover{text-decoration:underline; text-underline-offset:3px}
        .user-delete-btn{
          width:36px;
          height:36px;
          border-radius:10px;
          border:1px solid #f1c0c5;
          background:#fff0f1;
          color:#b91c1c;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          cursor:pointer;
          transition:.15s ease;
          box-shadow:0 2px 8px rgba(0,0,0,.06);
        }
        .user-delete-btn svg{
          width:16px;
          height:16px;
          stroke:currentColor;
          stroke-width:2;
          fill:none;
          stroke-linecap:round;
          stroke-linejoin:round;
        }
        .user-delete-btn:hover{
          border-color:#e9a8af;
          background:#ffe3e6;
          color:#991b1b;
          transform:translateY(-1px);
          box-shadow:0 6px 14px rgba(0,0,0,.1);
        }
        @media (max-width: 992px){
          .header-main{grid-template-columns:1fr;}
          .toolbar{justify-content:flex-start;}
        }
      </style>
    </head>
    <body class="min-h-screen bg-slate-50 text-slate-900">
      <div class="container-fluid">
      <main class="mx-auto max-w-[1800px] px-8 py-8">

        <div class="header-main">
          <div class="header-left">
            <p class="page-kicker">Administration</p>
            <h1>Users</h1>
          </div>

          <div class="toolbar">
            <a class="btn-primary-green" href="{{ url_for('users.user_add') }}">+ Add</a>
          </div>
        </div>

        <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div class="max-h-[calc(100vh-190px)] overflow-auto">
              <table class="standard-list-table min-w-full table-fixed divide-y divide-slate-200">
                <thead class="sticky top-0 z-10 bg-slate-100/95 backdrop-blur">
                  <tr class="text-left text-xs font-bold uppercase tracking-wide text-slate-500">
                    <th class="w-[90%] px-6 py-4">Username</th>
                    <th class="w-[10%] px-6 py-4 text-right"></th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-100 bg-white text-sm">
                  {% for u in rows %}
                  <tr class="user-row odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60 focus:outline-none focus:ring-2 focus:ring-sky-300" data-href="{{ url_for('users.user_edit', username=u['username']) }}" tabindex="0" onclick="window.location.href=this.dataset.href" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();window.location.href=this.dataset.href;}">
                    <td class="px-6 py-3 align-middle"><a class="username-cell user-edit-link" href="{{ url_for('users.user_edit', username=u['username']) }}" onclick="event.stopPropagation()">{{ u['username'] }}</a></td>
                    <td class="px-6 py-3 text-right align-middle">
                      {% if not u['is_builtin_admin'] and not u['is_current_user'] %}
                      <form method="post" action="{{ url_for('users.user_delete', username=u['username']) }}" class="m-0" onclick="event.stopPropagation()" onsubmit="event.stopPropagation(); return confirm('Delete user {{ u['username'] }}?');">
                        <button class="user-delete-btn" type="submit" title="Supprimer {{ u['username'] }}" aria-label="Supprimer {{ u['username'] }}">
                          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6l1-2h6l1 2"></path><path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path><path d="M14 10v6"></path></svg>
                        </button>
                      </form>
                      {% endif %}
                    </td>
                  </tr>
                  {% endfor %}
                  {% if rows|length == 0 %}
                  <tr><td colspan="2" class="text-center text-muted py-4">No users</td></tr>
                  {% endif %}
                </tbody>
              </table>
          </div>
        </section>

      </main>
      </div>
    </body>
    </html>
        """
        return render_inline(tmpl, rows=rows)

    # ---------- ADD ----------
    @bp.route("/users/add", methods=["GET", "POST"])
    @require_roles('admin')   # <-- admin only
    def user_add():
        err = None
        if request.method == "POST":
            user  = (request.form.get("username") or "").strip()
            p1    = request.form.get("password") or ""
            p2    = request.form.get("password2") or ""

            if not user:
                err = "Username is required."
            elif len(p1) < 8:
                err = "Password must be at least 8 characters."
            elif p1 != p2:
                err = "Passwords do not match."
            else:
                conn = get_db()
                exists = conn.execute("SELECT 1 FROM users WHERE username = ? LIMIT 1;", (user,)).fetchone()
                if exists:
                    err = "Username already exists."
                    conn.close()
                else:
                    ph = _hash_password(p1)
                    conn.execute(
                        "INSERT INTO users (username, password_hash) VALUES (?, ?);",
                        (user, ph),
                    )
                    conn.commit()
                    conn.close()
                    return redirect(url_for("users.users_list"))

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Add user</title>
    __HEAD_ASSETS__
      <style>
        :root{ --bg:#0b1220; --panel:#121a2b; --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06); --heading:#dbe8ff; }
        body{background:var(--bg); color:var(--text)}
        .card{background:var(--panel); border:1px solid var(--border)}
        h1,.section-title,.form-label{color:var(--heading)!important}
        .form-control, .form-select{
          background:#0f1726!important; color:var(--text)!important;
          border:1px solid var(--border)!important; caret-color:var(--text)
        }
        .form-control::placeholder{color:var(--muted); opacity:1}
        .form-control:focus, .form-select:focus{
          border-color:#29406b!important; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)!important
        }
        .toolbar{display:flex; gap:.6rem; justify-content:flex-end}
        .chip{
          display:inline-flex; align-items:center; gap:.6rem;
          background:linear-gradient(180deg,#182439,#121a2b); color:var(--text);
          border:1px solid var(--border); border-radius:12px; padding:.5rem .75rem; text-decoration:none;
          box-shadow:0 1px 0 rgba(0,0,0,.4), inset 0 0 0 1px rgba(255,255,255,.02);
        }
        .chip:hover{transform:translateY(-1px); border-color:#2b3d5c; box-shadow:0 6px 18px rgba(0,0,0,.35), inset 0 0 0 1px rgba(255,255,255,.03)}
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <div class="d-flex justify-content-between align-items-start mb-3">
          <h1 class="mb-1">Add user</h1>
          <div class="toolbar">

          </div>
        </div>

        {% if err %}<div class="alert alert-danger">{{ err }}</div>{% endif %}

        <form id="frmAdd" method="post" class="card shadow-sm p-3">
          <div class="row g-3">
            <div class="col-md-12">
              <label class="form-label fw-semibold">Username</label>
              <input name="username" type="text" class="form-control" placeholder="jdoe" required>
            </div>

            <div class="col-md-6">
              <label class="form-label fw-semibold">Password</label>
              <input id="password" name="password" type="password" class="form-control" placeholder="≥ 8 chars" required>
            </div>
            <div class="col-md-6">
              <label class="form-label fw-semibold">Confirm</label>
              <input id="password2" name="password2" type="password" class="form-control" placeholder="Confirm" required>
            </div>
          </div>

          <div class="mt-4">
            <button class="btn btn-success" type="submit">Create</button>
            <a class="btn btn-secondary" href="{{ url_for('users.users_list') }}">Cancel</a>
          </div>

          <div class="text-muted small mt-3">
            Passwords stored with PBKDF2-HMAC-SHA256 (Werkzeug).
          </div>
        </form>
      </div>

      <script>
      (function(){
        var f = document.getElementById("frmAdd");
        f.addEventListener("submit", function(ev){
          var p1 = document.getElementById("password").value || "";
          var p2 = document.getElementById("password2").value || "";
          if (p1.length < 8){ alert("Password must be at least 8 characters"); ev.preventDefault(); return; }
          if (p1 !== p2){ alert("Passwords do not match"); ev.preventDefault(); return; }
        });
      })();
      </script>
    </body>
    </html>
        """
        return render_inline(tmpl, err=err)

    @bp.route("/users/<username>/delete", methods=["POST"])
    @require_roles('admin')
    def user_delete(username: str):
        conn = get_db()
        row = conn.execute(
            "SELECT username FROM users WHERE username=? LIMIT 1;",
            (username,),
        ).fetchone()
        if not row:
            conn.close()
            abort(404, "user not found")

        uname = ((row["username"] or "").strip().lower())
        current_username = ((session.get("username") or "").strip().lower())
        if _is_builtin_admin(row):
            conn.close()
            abort(400, "cannot delete built-in admin")
        if uname and uname == current_username:
            conn.close()
            abort(400, "cannot delete current user")

        conn.execute("DELETE FROM users WHERE username=?;", (username,))
        conn.commit()
        conn.close()
        return redirect(url_for("users.users_list"))

    # ---------- EDIT ----------
    @bp.route("/users/<username>/edit", methods=["GET", "POST"])
    @require_roles('admin')   # <-- admin only
    def user_edit(username: str):
        conn = get_db()

        if request.method == "POST":
            p1    = request.form.get("password") or ""
            p2    = request.form.get("password2") or ""

            row_cur = conn.execute(
                "SELECT username FROM users WHERE username=? LIMIT 1;",
                (username,),
            ).fetchone()
            if not row_cur:
                conn.close()
                abort(404, "user not found")

            # Password change if provided
            if p1 or p2:
                if len(p1) < 8:
                    conn.close()
                    return redirect(url_for("users.user_edit", username=username, err="pwlen"))
                if p1 != p2:
                    conn.close()
                    return redirect(url_for("users.user_edit", username=username, err="pwmismatch"))
                ph = _hash_password(p1)
                conn.execute("UPDATE users SET password_hash=? WHERE username=?;", (ph, username))
                conn.commit()

            conn.close()
            return redirect(url_for("users.users_list"))

        row = conn.execute(
            "SELECT username FROM users WHERE username=? LIMIT 1;",
            (username,),
        ).fetchone()
        conn.close()
        if not row:
            abort(404, "user not found")

        err = (request.args.get("err") or "").strip()

        tmpl = r"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>Edit user</title>
    __HEAD_ASSETS__
      <style>
        :root{ --bg:#0b1220; --panel:#121a2b; --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06); --heading:#dbe8ff; }
        body{background:var(--bg); color:var(--text)}
        .card{background:var(--panel); border:1px solid var(--border)}
        h1,.section-title,.form-label{color:var(--heading)!important}
        .form-control, .form-select{
          background:#0f1726!important; color:var(--text)!important;
          border:1px solid var(--border)!important; caret-color:var(--text)
        }
        .form-control::placeholder{color:var(--muted); opacity:1}
        .form-control:focus, .form-select:focus{
          border-color:#29406b!important; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)!important
        }
        .toolbar{display:flex; gap:.6rem; justify-content:flex-end}
        .chip{
          display:inline-flex; align-items:center; gap:.6rem;
          background:linear-gradient(180deg,#182439,#121a2b); color:var(--text);
          border:1px solid var(--border); border-radius:12px; padding:.5rem .75rem; text-decoration:none;
          box-shadow:0 1px 0 rgba(0,0,0,.4), inset 0 0 0 1px rgba(255,255,255,.02);
        }
        .chip:hover{transform:translateY(-1px); border-color:#2b3d5c; box-shadow:0 6px 18px rgba(0,0,0,.35), inset 0 0 0 1px rgba(255,255,255,.03)}
      </style>
    </head>
    <body class="p-4">
      <div class="container-fluid">

        <div class="d-flex justify-content-between align-items-start mb-3">
          <div>
            <h1 class="mb-1">Edit user</h1>
          </div>
          <div class="toolbar">
          </div>
        </div>

        <form id="frmEdit" method="post" class="card shadow-sm p-3">
          <div class="row g-3">
            <div class="col-md-12">
              <label class="form-label fw-semibold">Username</label>
              <input type="text" class="form-control" value="{{ row['username'] or '' }}" disabled>
            </div>
          </div>

          <hr class="my-4"/>

          <h6 class="section-title mb-3">Change password (optional)</h6>
          <div class="row g-3">
            <div class="col-md-6">
              <label class="form-label">New password</label>
              <input id="password" name="password" type="password" class="form-control" placeholder="≥ 8 chars">
            </div>
            <div class="col-md-6">
              <label class="form-label">Confirm</label>
              <input id="password2" name="password2" type="password" class="form-control" placeholder="Confirm">
            </div>
          </div>

          <div class="mt-4 d-flex gap-2">
            <button class="btn btn-primary" type="submit">Save</button>
            <a class="btn btn-secondary" href="{{ url_for('users.users_list') }}">Cancel</a>
          </div>
        </form>
      </div>

      <script>
      (function(){
        var err = "{{ err }}";
        if (err === "pwlen") { alert("Password must be at least 8 characters"); }
        if (err === "pwmismatch") { alert("Passwords do not match"); }

        var f  = document.getElementById("frmEdit");
        f.addEventListener("submit", function(ev){
          var p1 = document.getElementById("password").value || "";
          var p2 = document.getElementById("password2").value || "";
          if (p1.length === 0 && p2.length === 0) return;
          if (p1.length < 8) { alert("Password must be at least 8 characters"); ev.preventDefault(); return; }
          if (p1 !== p2)    { alert("Passwords do not match"); ev.preventDefault(); return; }
        });
      })();
      </script>
    </body>
    </html>
        """
        return render_inline(
            tmpl,
            row=row,
            err=err
        )

    return bp


users_bp = _build_users_bp()
del _build_users_bp
