"""
=============================================================================
bp_network.py - Network access control (Option A — network restriction)
=============================================================================

Management page to review the networks that have presented themselves to the
web service and decide which ones are allowed.

  - Every gated request records its source network (Blocked by default).
  - Private RFC1918 addresses are grouped to their whole block
    (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16); public addresses (NAT) are
    recorded as a single /32 (or /128 for IPv6).
  - An admin flips an entry Blocked <-> Allow, edits its range/mask, adds an
    arbitrary CIDR manually (including 0.0.0.0/0 to allow everything), or
    deletes an entry.

The actual enforcement lives in app.py (_network_guard) + core.is_ip_allowed.
"""

import datetime
import ipaddress

from flask import Blueprint, request, redirect, url_for, abort
from core import get_db, require_roles, render_inline, _invalidate_networks_cache, is_ip_allowed, _clean_source_ip

bp = Blueprint("network", __name__)


def _now() -> str:
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _normalize_cidr(raw: str) -> str:
    """Validate and normalize a CIDR or single IP. Returns '' if invalid."""
    s = (raw or "").strip()
    if not s:
        return ""
    try:
        return str(ipaddress.ip_network(s, strict=False))
    except ValueError:
        return ""


# ---------- LIST ----------
@bp.route("/network")
@require_roles("admin")
def network_list():
    conn = get_db()
    try:
        rows_db = conn.execute(
            """
            SELECT network, status
            FROM networks
            ORDER BY
              CASE WHEN LOWER(status) = 'allow' THEN 0 ELSE 1 END,
              LOWER(network);
            """
        ).fetchall()
    finally:
        conn.close()

    rows = []
    for r in rows_db:
        item = dict(r)
        item["is_allow"] = (str(item.get("status") or "").strip().lower() == "allow")
        rows.append(item)

    allowed_count = sum(1 for r in rows if r["is_allow"])

    # IP as the web service actually sees it (after the reverse proxy / ProxyFix),
    # with any trailing ':port' stripped so it parses as a plain IP.
    viewer_ip = _clean_source_ip(request.remote_addr or "")
    viewer_allowed = is_ip_allowed(request.remote_addr or "")

    tmpl = r"""
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Network</title>
  <script src="https://cdn.tailwindcss.com"></script>
__HEAD_ASSETS__
  <style>
    body{background:#f8fafc; color:#0f172a}
    a, a:hover{color:#1d6fd1}

    .header-main{
      display:grid;
      grid-template-columns:minmax(220px,1fr) auto;
      align-items:center;
      gap:1rem;
      margin-bottom:1.25rem;
    }
    .header-left{min-width:0}
    .page-kicker{
      margin:0; color:#94a3b8; font-size:.75rem; font-weight:700;
      letter-spacing:.22em; text-transform:uppercase;
    }
    .header-left h1{
      margin:.5rem 0 0; color:#020617!important; line-height:1.05;
      font-size:1.875rem; font-weight:800; letter-spacing:-.025em;
    }
    .add-form{
      display:flex; align-items:center; gap:.5rem; flex-wrap:wrap;
      justify-content:flex-end;
    }
    .add-form input[type=text], .add-form select{
      border:1px solid #cbd5e1; border-radius:8px; padding:.45rem .6rem;
      background:#fff; color:#0f172a; font-size:.9rem; min-height:38px;
    }
    .add-form input[type=text]{min-width:240px; font-family:"Roboto Mono",Consolas,monospace}
    .btn-add{
      background:#16a34a; color:#fff; border:0; border-radius:8px;
      padding:.5rem .9rem; font-weight:700; cursor:pointer; min-height:38px;
    }
    .btn-add:hover{background:#15803d}

    .net-cell{font-family:"Roboto Mono",Consolas,monospace; font-weight:700}

    .badge-status{
      display:inline-block; padding:.2rem .6rem; border-radius:999px;
      font-size:.78rem; font-weight:700;
    }
    .badge-allow{background:#dcfce7; color:#166534; border:1px solid #bbf7d0}
    .badge-block{background:#fee2e2; color:#991b1b; border:1px solid #fecaca}

    .btn-toggle{
      border-radius:8px; padding:.35rem .7rem; font-weight:700; cursor:pointer;
      font-size:.82rem; border:1px solid transparent;
    }
    .btn-allow{background:#16a34a; color:#fff}
    .btn-allow:hover{background:#15803d}
    .btn-block{background:#fff; color:#b45309; border-color:#fcd34d}
    .btn-block:hover{background:#fffbeb}

    .net-icon-btn{
      width:36px; height:36px; border-radius:10px; display:inline-flex;
      align-items:center; justify-content:center; cursor:pointer; transition:.15s ease;
    }
    .net-icon-btn svg{width:16px; height:16px; stroke:currentColor; stroke-width:2; fill:none; stroke-linecap:round; stroke-linejoin:round}
    .net-edit-btn{border:1px solid #bcd3f0; background:#eff6ff; color:#1d4ed8}
    .net-edit-btn:hover{border-color:#93b8ec; background:#dceafe}
    .net-delete-btn{border:1px solid #f1c0c5; background:#fff0f1; color:#b91c1c}
    .net-delete-btn:hover{border-color:#e9a8af; background:#ffe3e6; color:#991b1b}

    .hint{color:#64748b; font-size:.85rem; margin-bottom:1rem}
    .viewer-ip{
      display:flex; align-items:center; gap:.6rem; flex-wrap:wrap;
      background:#fff; border:1px solid #e2e8f0; border-radius:12px;
      padding:.65rem .9rem; margin-bottom:1rem; box-shadow:0 1px 3px rgba(16,42,67,.05);
      font-size:.9rem; color:#334155;
    }
    .viewer-ip .label{color:#64748b}
    @media (max-width: 992px){
      .header-main{grid-template-columns:1fr;}
      .add-form{justify-content:flex-start;}
    }
  </style>
</head>
<body class="min-h-screen bg-slate-50 text-slate-900">
  <div class="container-fluid">
  <main class="mx-auto max-w-[1800px] px-8 py-8">

    <div class="header-main">
      <div class="header-left">
        <p class="page-kicker">Administration</p>
        <h1>Network</h1>
      </div>

      <form class="add-form" method="post" action="{{ url_for('network.network_add') }}">
        <input type="text" name="cidr" placeholder="10.0.0.0/8  or  0.0.0.0/0" required>
        <select name="status">
          <option value="Allow" selected>Allow</option>
          <option value="Blocked">Blocked</option>
        </select>
        <button class="btn-add" type="submit">+ Add range</button>
      </form>
    </div>

    <div class="viewer-ip">
      <span class="label">Your IP as seen by this server:</span>
      <span class="net-cell">{{ viewer_ip or '—' }}</span>
      {% if viewer_allowed %}
        <span class="badge-status badge-allow">Allow</span>
      {% else %}
        <span class="badge-status badge-block">Blocked</span>
      {% endif %}
    </div>

    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
      <div class="max-h-[calc(100vh-260px)] overflow-auto">
        <table class="standard-list-table min-w-full table-fixed divide-y divide-slate-200">
          <thead class="sticky top-0 z-10 bg-slate-100/95 backdrop-blur">
            <tr class="text-left text-xs font-bold uppercase tracking-wide text-slate-500">
              <th class="w-[55%] px-6 py-4">Network</th>
              <th class="w-[15%] px-6 py-4">Status</th>
              <th class="w-[30%] px-6 py-4 text-right">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-slate-100 bg-white text-sm">
            {% for n in rows %}
            <tr class="odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60">
              <td class="px-6 py-3 align-middle"><span class="net-cell">{{ n['network'] }}</span></td>
              <td class="px-6 py-3 align-middle">
                {% if n['is_allow'] %}
                  <span class="badge-status badge-allow">Allow</span>
                {% else %}
                  <span class="badge-status badge-block">Blocked</span>
                {% endif %}
              </td>
              <td class="px-6 py-3 text-right align-middle">
                <div class="inline-flex items-center gap-2 justify-end">
                  <form method="post" action="{{ url_for('network.network_toggle') }}" class="m-0">
                    <input type="hidden" name="network" value="{{ n['network'] }}">
                    {% if n['is_allow'] %}
                      <button class="btn-toggle btn-block" type="submit">Block</button>
                    {% else %}
                      <button class="btn-toggle btn-allow" type="submit">Allow</button>
                    {% endif %}
                  </form>
                  <button type="button" class="net-icon-btn net-edit-btn" title="Edit range / mask"
                          aria-label="Edit" data-edit-network="{{ n['network'] }}">
                    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h9"></path><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"></path></svg>
                  </button>
                  <form method="post" action="{{ url_for('network.network_delete') }}" class="m-0"
                        onsubmit="return confirm('Delete {{ n['network'] }}?');">
                    <input type="hidden" name="network" value="{{ n['network'] }}">
                    <button class="net-icon-btn net-delete-btn" type="submit" title="Delete {{ n['network'] }}" aria-label="Delete">
                      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6l1-2h6l1 2"></path><path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path><path d="M14 10v6"></path></svg>
                    </button>
                  </form>
                </div>
              </td>
            </tr>
            {% endfor %}
            {% if rows|length == 0 %}
            <tr><td colspan="3" class="text-center text-muted py-4">No networks recorded yet</td></tr>
            {% endif %}
          </tbody>
        </table>
      </div>
    </section>

  </main>
  </div>

  <script>
    var EDIT_URL = {{ url_for('network.network_edit')|tojson }};
    document.querySelectorAll('[data-edit-network]').forEach(function(btn){
      btn.addEventListener('click', function(){
        var cur = btn.getAttribute('data-edit-network') || '';
        var v = window.prompt('New range / mask (CIDR or IP):', cur);
        if (v === null) return;
        v = v.trim();
        if (!v || v === cur) return;
        var f = document.createElement('form');
        f.method = 'post';
        f.action = EDIT_URL;
        var a = document.createElement('input'); a.type='hidden'; a.name='network'; a.value=cur; f.appendChild(a);
        var b = document.createElement('input'); b.type='hidden'; b.name='new_network'; b.value=v; f.appendChild(b);
        document.body.appendChild(f);
        f.submit();
      });
    });
  </script>
</body>
</html>
    """
    return render_inline(tmpl, rows=rows, allowed_count=allowed_count,
                         viewer_ip=viewer_ip, viewer_allowed=viewer_allowed)


# ---------- TOGGLE ----------
@bp.route("/network/toggle", methods=["POST"])
@require_roles("admin")
def network_toggle():
    network = (request.form.get("network") or "").strip()
    if not network:
        abort(400, "missing network")
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT status FROM networks WHERE network = ? LIMIT 1;", (network,)
        ).fetchone()
        if not row:
            abort(404, "network not found")
        current = str(row["status"] or "").strip().lower()
        new_status = "Blocked" if current == "allow" else "Allow"
        conn.execute(
            "UPDATE networks SET status = ?, last_seen = ? WHERE network = ?;",
            (new_status, _now(), network),
        )
        conn.commit()
    finally:
        conn.close()
    _invalidate_networks_cache()
    return redirect(url_for("network.network_list"))


# ---------- EDIT (change range / mask) ----------
@bp.route("/network/edit", methods=["POST"])
@require_roles("admin")
def network_edit():
    old = (request.form.get("network") or "").strip()
    new = _normalize_cidr(request.form.get("new_network") or "")
    if not old:
        abort(400, "missing network")
    if not new:
        abort(400, "invalid CIDR or IP")
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT 1 FROM networks WHERE network = ? LIMIT 1;", (old,)
        ).fetchone()
        if not row:
            abort(404, "network not found")
        if new != old:
            dup = conn.execute(
                "SELECT 1 FROM networks WHERE network = ? LIMIT 1;", (new,)
            ).fetchone()
            if dup:
                abort(400, "target range already exists")
            conn.execute(
                "UPDATE networks SET network = ?, last_seen = ? WHERE network = ?;",
                (new, _now(), old),
            )
            conn.commit()
    finally:
        conn.close()
    _invalidate_networks_cache()
    return redirect(url_for("network.network_list"))


# ---------- ADD (manual range) ----------
@bp.route("/network/add", methods=["POST"])
@require_roles("admin")
def network_add():
    cidr = _normalize_cidr(request.form.get("cidr") or "")
    if not cidr:
        abort(400, "invalid CIDR or IP")
    status = (request.form.get("status") or "Allow").strip().lower()
    status = "Allow" if status == "allow" else "Blocked"

    conn = get_db()
    try:
        exists = conn.execute(
            "SELECT 1 FROM networks WHERE network = ? LIMIT 1;", (cidr,)
        ).fetchone()
        now = _now()
        if exists:
            conn.execute(
                "UPDATE networks SET status = ?, last_seen = ? WHERE network = ?;",
                (status, now, cidr),
            )
        else:
            conn.execute(
                "INSERT INTO networks (network, kind, status, first_seen, last_seen, hits) "
                "VALUES (?, 'manual', ?, ?, ?, 0);",
                (cidr, status, now, now),
            )
        conn.commit()
    finally:
        conn.close()
    _invalidate_networks_cache()
    return redirect(url_for("network.network_list"))


# ---------- DELETE ----------
@bp.route("/network/delete", methods=["POST"])
@require_roles("admin")
def network_delete():
    network = (request.form.get("network") or "").strip()
    if not network:
        abort(400, "missing network")
    conn = get_db()
    try:
        conn.execute("DELETE FROM networks WHERE network = ?;", (network,))
        conn.commit()
    finally:
        conn.close()
    _invalidate_networks_cache()
    return redirect(url_for("network.network_list"))
